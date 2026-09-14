import Foundation

protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// No cache, no cookies, no credential storage: the only thing this session sends is the
/// usage request, and it keeps nothing afterwards.
struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = ClaudeUsageAPI.timeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Anthropic's OAuth usage endpoint, exactly as reference/request.md records it
/// (`probe_limits` in omarchy-agent-usage-claude).
enum ClaudeUsageAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let timeout: TimeInterval = 10

    enum ProbeResult: Sendable, Equatable {
        case limits([UsageRecord.Limit])
        /// `transport` means no server answered; `retryAfter` is the 429 Retry-After, in seconds.
        case failed(helpText: String, transport: Bool, retryAfter: TimeInterval?)
    }

    static func request(accessToken: String) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func probe(accessToken: String, transport: any HTTPTransport) async -> ProbeResult {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request(accessToken: accessToken))
        } catch {
            return transportFailure
        }
        return interpret(status: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "retry-after"), body: data)
    }

    static func interpret(status: Int, retryAfter: String?, body: Data) -> ProbeResult {
        guard (200..<300).contains(status) else {
            let retryAfter = retryAfter?.trimmingCharacters(in: .whitespaces) ?? ""
            let helpText = status == 429
                ? "Anthropic's usage endpoint is rate limiting checks right now"
                    + (retryAfter.isEmpty ? "" : " (retry after \(retryAfter)s)")
                    + ". Local Claude Code stats are still shown."
                : "Anthropic's usage endpoint returned status \(status). Local Claude Code stats are still shown."
            return .failed(helpText: helpText, transport: false, retryAfter: status == 429 ? TimeInterval(retryAfter) : nil)
        }
        // The collector parses the body inside the same try as the request, so an unreadable
        // body reads as an unreachable endpoint.
        guard let payload = try? JSONSerialization.jsonObject(with: body) else { return transportFailure }
        let limits = parseLimits(payload)
        guard !limits.isEmpty else {
            return .failed(
                helpText: "Anthropic's usage endpoint returned no limits. Local Claude Code stats are still shown.",
                transport: false, retryAfter: nil
            )
        }
        return .limits(limits)
    }

    static let transportFailure = ProbeResult.failed(
        helpText: "Couldn't reach Anthropic's usage endpoint. Retrying shortly. Local Claude Code stats are still shown.",
        transport: true, retryAfter: nil
    )

    // MARK: - Payload

    static func parseLimits(_ payload: Any) -> [UsageRecord.Limit] {
        guard let payload = payload as? [String: Any] else { return [] }
        let oauthApps = payload["seven_day_oauth_apps"] as? [String: Any]
        let weekly = (oauthApps?.isEmpty == false) ? oauthApps : payload["seven_day"] as? [String: Any]
        let session = payload["five_hour"] as? [String: Any]
        let entries = (payload["limits"] as? [Any])?.compactMap { $0 as? [String: Any] }

        // One payload speaks one convention: any value >= 1 means percentages.
        var raw: [Any?] = [session?["utilization"], weekly?["utilization"]]
        raw += entries?.map { $0["percent"] } ?? []
        let percentScale = raw.contains { parseUtilization($0) >= 1 }

        var limits: [UsageRecord.Limit] = []
        if let session {
            let percent = normalizeUtilization(session["utilization"], percentScale: percentScale)
            if percent >= 0 {
                limits.append(.init(label: "Session (5-hour)", percent: percent, resetsAt: normalizeResetAt(session["resets_at"])))
            }
        }
        if let weekly {
            let percent = normalizeUtilization(weekly["utilization"], percentScale: percentScale)
            if percent >= 0 {
                limits.append(.init(label: "Weekly (7-day)", percent: percent, resetsAt: normalizeResetAt(weekly["resets_at"])))
            }
        }
        limits += scopedLimits(entries ?? [], percentScale: percentScale)
        return limits
    }

    /// `scoped_limits`: the only place a model-scoped allowance appears. Model and window
    /// together name a limit, and each pair is kept once.
    private static func scopedLimits(_ entries: [[String: Any]], percentScale: Bool) -> [UsageRecord.Limit] {
        var out: [UsageRecord.Limit] = []
        var seen: Set<String> = []
        for entry in entries {
            guard let scope = entry["scope"] as? [String: Any], let model = scope["model"] as? [String: Any] else { continue }
            let name = (truthyString(model["display_name"]) ?? truthyString(model["id"]) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let kind = (truthyString(entry["kind"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let key = name + "\u{0}" + kind
            guard !name.isEmpty, !seen.contains(key) else { continue }
            let percent = normalizeUtilization(entry["percent"], percentScale: percentScale)
            guard percent >= 0 else { continue }
            seen.insert(key)
            let window = scopedWindow(kind)
            let title = window.isEmpty ? name : name + " " + window
            out.append(.init(label: title, title: title, percent: percent, resetsAt: normalizeResetAt(entry["resets_at"])))
        }
        return out
    }

    static func scopedWindow(_ kind: String) -> String {
        let text = kind.lowercased()
        if text.contains("month") { return "Monthly" }
        if text.contains("week") || text.contains("day") { return "Weekly" }
        if text.contains("hour") || text.contains("session") { return "Session" }
        return ""
    }

    /// `parse_utilization`: a number, or a numeric string with an optional `%`. NaN otherwise.
    static func parseUtilization(_ value: Any?) -> Double {
        switch value {
        case let number as NSNumber where !isBoolean(number):
            return number.doubleValue
        case let string as String:
            return Double(string.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")) ?? .nan
        default:
            return .nan
        }
    }

    /// `normalize_utilization`: a fraction capped at 1, or -1 for "no usable value".
    static func normalizeUtilization(_ value: Any?, percentScale: Bool) -> Double {
        let n = parseUtilization(value)
        guard n >= 0 else { return -1 }
        return percentScale || n > 1 ? min(1, n / 100) : min(1, n)
    }

    /// `normalize_reset_at`: epoch seconds or milliseconds become ISO 8601 UTC; an ISO string is
    /// kept, with a `Z` suffix written as `+00:00`; anything else passes through.
    static func normalizeResetAt(_ value: Any?) -> String {
        let raw: String
        switch value {
        case nil, is NSNull: return ""
        case let number as NSNumber where !isBoolean(number):
            raw = number.doubleValue == number.doubleValue.rounded() ? String(number.int64Value) : number.stringValue
        case let string as String: raw = string.trimmingCharacters(in: .whitespacesAndNewlines)
        default: raw = String(describing: value!)
        }
        guard !raw.isEmpty else { return "" }
        if raw.allSatisfy(\.isASCII), raw.allSatisfy(\.isNumber), var ms = Double(raw) {
            if ms < 1e12 { ms *= 1000 }
            return OmarchyDate.isoformat(Date(timeIntervalSince1970: ms / 1000))
        }
        guard OmarchyDate.parse(raw) != nil else { return raw }
        return raw.hasSuffix("Z") ? String(raw.dropLast()) + "+00:00" : raw
    }

    private static func truthyString(_ value: Any?) -> String? {
        switch value {
        case let string as String where !string.isEmpty: return string
        case let number as NSNumber where !isBoolean(number) && number != 0: return number.stringValue
        default: return nil
        }
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
