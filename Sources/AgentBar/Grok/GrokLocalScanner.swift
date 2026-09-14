import Foundation
import OSLog

/// Grok CLI usage on this machine. Omarchy ships no Grok collector, so this follows Grok's own
/// documentation (`~/.grok/docs/user-guide`): per-session token totals persisted in
/// `sessions/<encoded-cwd>/<session-id>/usage.json` (the JSON `grok usage <session-id>` prints),
/// and the account allowance Grok logs to `logs/unified.jsonl` when it fetches its credits
/// config. Everything here is read-only; only AgentBar's own cache is written.
struct GrokLocalScanner: Sendable {
    /// The same reuse windows as the other collectors: 20 s, or 900 s when the panel opens.
    static let scanReuse: TimeInterval = 20
    static let limitsOnlyReuse: TimeInterval = 900

    /// `~/.grok`.
    let grokHome: URL
    let cacheDirectory: URL
    let calendar: Calendar

    static func live(cacheDirectory: URL) -> GrokLocalScanner {
        GrokLocalScanner(
            grokHome: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".grok", directoryHint: .isDirectory),
            cacheDirectory: cacheDirectory,
            calendar: .current
        )
    }

    struct Billing: Sendable, Equatable {
        var limit: UsageRecord.Limit?
        var tier: String
    }

    // MARK: - Local stats

    func stats(now: Date, maxAge: TimeInterval) async -> LocalStats {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: statsBlocking(now: now, maxAge: maxAge))
            }
        }
    }

    /// Reused while younger than `maxAge` and scanned on the same local day.
    func statsBlocking(now: Date, maxAge: TimeInterval) -> LocalStats {
        let today = LocalDay.string(now, calendar: calendar)
        if maxAge > 0, let cached = readCache(), cached.scanDate == today {
            let age = now.timeIntervalSince1970 - cached.scannedAtMs / 1000
            if age >= 0, age <= maxAge { return cached.stats }
        }
        let stats = scanAll(now: now)
        writeCache(ScanCache(scanDate: today, scannedAtMs: now.timeIntervalSince1970 * 1000, stats: stats))
        return stats
    }

    /// Every top-level session's `usage.json`. Each recorded turn counts on the day it ended,
    /// under its primary model; a session without turns counts its totals on its last update.
    func scanAll(now: Date) -> LocalStats {
        var tally = StatsAccumulator(now: now, calendar: calendar)
        // A resumed or forked session carries its parent's history, and the same turn must not
        // count twice. A turn is its end time, size and model.
        var seenTurns: Set<String> = []
        for file in usageFiles() {
            guard let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let session = root["session"] as? [String: Any] ?? [:]
            let sessionID = PyNumber.truthyString(root["sessionId"]) ?? file.deletingLastPathComponent().lastPathComponent
            let sessionModel = PyNumber.truthyString(session["primaryModelId"]) ?? "grok"
            let turns = (root["turns"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }

            if turns.isEmpty {
                add(session, model: sessionModel, at: root["updatedAt"], session: sessionID, now: now, into: &tally)
                continue
            }
            for turn in turns {
                let model = PyNumber.truthyString(turn["primaryModelId"]) ?? sessionModel
                let key = "\(turn["endedAt"] ?? "")|\(PyNumber.rounded(turn["totalTokens"]))|\(model)"
                guard seenTurns.insert(key).inserted else { continue }
                add(turn, model: model, at: turn["endedAt"], session: sessionID, now: now, into: &tally)
            }
        }
        return tally.stats
    }

    /// Grok counts cache reads and writes inside `inputTokens` (they "sum back to
    /// session_input_tokens", 25-status-line.md) and reasoning inside `outputTokens`
    /// (`totalTokens` is input plus output), so each category is counted once.
    private func add(_ usage: [String: Any], model: String, at time: Any?, session: String, now: Date, into tally: inout StatsAccumulator) {
        let cacheRead = PyNumber.rounded(usage["cachedReadTokens"])
        let cacheWrite = PyNumber.rounded(usage["cacheCreationTokens"])
        let input = max(0, PyNumber.rounded(usage["inputTokens"]) - cacheRead - cacheWrite)
        let output = PyNumber.rounded(usage["outputTokens"])
        guard input + output + cacheRead + cacheWrite > 0 else { return }
        tally.add(
            day: LocalDay.from(time, now: now, calendar: calendar),
            session: session, model: model,
            input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite
        )
    }

    /// `sessions/<encoded-cwd>/<session-id>/usage.json`. Subagent sessions below a session are
    /// left out, since Grok doesn't document whether its parent's totals already include them.
    private func usageFiles() -> [URL] {
        let sessions = grokHome.appending(path: "sessions", directoryHint: .isDirectory)
        let manager = FileManager.default
        var files: [URL] = []
        for directory in (try? manager.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)) ?? [] {
            for session in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                let usage = session.appending(path: "usage.json")
                if manager.fileExists(atPath: usage.path(percentEncoded: false)) { files.append(usage) }
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    // MARK: - Allowance

    private static let billingMessage = "billing: fetched credits config"
    private static let billingNeedle = Data(billingMessage.utf8)

    /// The newest credits config Grok logged: the share of the allowance used, the billing
    /// period, and the subscription tier. Grok only logs it while it runs, so this is the value
    /// as of Grok's last fetch; like any cached limit it is dropped once its period has ended.
    func latestBilling(now: Date) -> Billing? {
        let log = grokHome.appending(path: "logs/unified.jsonl")
        guard let data = try? Data(contentsOf: log, options: .alwaysMapped) else { return nil }
        var tier: String?
        var lineEnd = data.endIndex
        while lineEnd > data.startIndex {
            let lineStart = data[data.startIndex..<lineEnd].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
            let line = data[lineStart..<lineEnd]
            lineEnd = lineStart == data.startIndex ? data.startIndex : lineStart - 1

            guard line.range(of: Self.billingNeedle) != nil, let entry = JSONLines.object(line),
                  entry["msg"] as? String == Self.billingMessage else { continue }
            let context = entry["ctx"] as? [String: Any] ?? [:]
            let config = context["config"] as? [String: Any] ?? [:]
            if tier == nil { tier = PyNumber.truthyString(context["subscriptionTier"]) }
            guard let percent = config["creditUsagePercent"] as? NSNumber, CFGetTypeID(percent) != CFBooleanGetTypeID() else { continue }

            let start = (config["billingPeriodStart"] as? String).flatMap(OmarchyDate.parse)
            let endText = config["billingPeriodEnd"] as? String ?? ""
            let end = OmarchyDate.parse(endText)
            let limit = UsageRecord.Limit(
                label: Self.periodLabel(start: start, end: end),
                percent: min(1, max(0, percent.doubleValue / 100)),
                resetsAt: end == nil ? "" : endText
            )
            let open = end.map { $0 > now } ?? true
            return Billing(limit: open ? limit : nil, tier: tier ?? "")
        }
        return tier.map { Billing(limit: nil, tier: $0) }
    }

    /// Named after the billing period's length, the way the other collectors name their windows.
    static func periodLabel(start: Date?, end: Date?) -> String {
        guard let start, let end, end > start else { return "Credits" }
        let days = Int((end.timeIntervalSince(start) / 86_400).rounded())
        switch days {
        case 7: return "Weekly (7-day)"
        case 28...31: return "Monthly (30-day)"
        case 1...: return "Credits (\(days)-day)"
        default: return "Credits"
        }
    }

    // MARK: - Cache

    struct ScanCache: Codable {
        var scanDate: String
        var scannedAtMs: Double
        var stats: LocalStats
    }

    var cacheURL: URL { cacheDirectory.appending(path: "grok-local.json") }

    private func readCache() -> ScanCache? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(ScanCache.self, from: data)
    }

    private func writeCache(_ cache: ScanCache) {
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
        } catch {
            Logger.collector.error("Couldn't write the Grok scan cache: \(String(describing: error), privacy: .public)")
        }
    }
}
