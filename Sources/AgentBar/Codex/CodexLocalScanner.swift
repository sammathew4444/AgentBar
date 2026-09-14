import Foundation
import OSLog
import SQLite3

/// Codex usage on this machine, gathered as omarchy-agent-usage-codex does: native Codex CLI
/// session files touched in the last 30 days, plus the sessions pi, omp and opencode ran on an
/// OpenAI provider. Everything here is read-only; only AgentBar's own cache is written.
struct CodexLocalScanner: Sendable {
    /// `SCAN_REUSE_SECONDS`: dedups overlapping runs without skipping a real rescan.
    static let scanReuse: TimeInterval = 20
    /// `LIMITS_ONLY_REUSE_SECONDS`: a panel opening promises fresh limits only.
    static let limitsOnlyReuse: TimeInterval = 900
    /// Native session files older than this aren't read, so "all-time" means the last 30 days.
    static let sessionWindow: TimeInterval = 30 * 24 * 3600

    /// `$CODEX_HOME`, default `~/.codex`. Its `sessions/` and `archived_sessions/` are read.
    let codexHome: URL
    /// `~/.pi/agent/sessions` and `~/.omp/agent/sessions`.
    let piSessionRoots: [URL]
    /// `$XDG_DATA_HOME/opencode/opencode.db`, default under `~/.local/share`.
    let opencodeDatabase: URL
    let cacheDirectory: URL
    let calendar: Calendar

    static func live(cacheDirectory: URL) -> CodexLocalScanner {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        func directory(_ variable: String) -> URL? {
            guard let value = environment[variable], !value.isEmpty else { return nil }
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
        }
        let dataHome = directory("XDG_DATA_HOME") ?? home.appending(path: ".local/share", directoryHint: .isDirectory)
        return CodexLocalScanner(
            codexHome: directory("CODEX_HOME") ?? home.appending(path: ".codex", directoryHint: .isDirectory),
            piSessionRoots: [
                home.appending(path: ".pi/agent/sessions", directoryHint: .isDirectory),
                home.appending(path: ".omp/agent/sessions", directoryHint: .isDirectory),
            ],
            opencodeDatabase: dataHome.appending(path: "opencode/opencode.db"),
            cacheDirectory: cacheDirectory,
            calendar: .current
        )
    }

    func stats(now: Date, maxAge: TimeInterval) async -> LocalStats {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: statsBlocking(now: now, maxAge: maxAge))
            }
        }
    }

    /// `cached_local_stats`: a versioned envelope, reused only on the scan's own day and while
    /// its age is between zero and `maxAge`. A scan cut short isn't cached.
    func statsBlocking(now: Date, maxAge: TimeInterval) -> LocalStats {
        let today = LocalDay.string(now, calendar: calendar)
        if maxAge > 0, let cached = readCache(), cached.schemaVersion == 1, cached.scanDate == today {
            let age = now.timeIntervalSince1970 - cached.scannedAtMs / 1000
            if age >= 0, age <= maxAge { return cached.stats }
        }
        let (stats, complete) = scanAll(now: now)
        if complete {
            writeCache(ScanCache(schemaVersion: 1, scanDate: today, scannedAtMs: now.timeIntervalSince1970 * 1000, stats: stats))
        }
        return stats
    }

    /// `run_local_scans`: all three sources feed one tally.
    func scanAll(now: Date) -> (stats: LocalStats, complete: Bool) {
        var tally = StatsAccumulator(now: now, calendar: calendar)
        scanPiSessions(now: now, into: &tally)
        scanNativeSessions(now: now, into: &tally)
        let complete = scanOpencode(now: now, into: &tally)
        return (tally.stats, complete)
    }

    // MARK: - Native sessions

    private static let tokenCount = Data("token_count".utf8)
    private static let turnContext = Data("turn_context".utf8)

    /// `scan_native_codex_sessions`: `turn_context` sets the model for the lines after it, and each
    /// `token_count` adds its turn's `last_token_usage`. Cached input is part of `input_tokens` and
    /// reasoning is part of `output_tokens`, so neither is counted twice.
    private func scanNativeSessions(now: Date, into tally: inout StatsAccumulator) {
        let cutoff = now.addingTimeInterval(-Self.sessionWindow)
        for root in ["sessions", "archived_sessions"] {
            for file in JSONLines.files(under: codexHome.appending(path: root, directoryHint: .isDirectory)) {
                guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified >= cutoff else { continue }
                let path = file.path(percentEncoded: false)
                var model = "codex"
                JSONLines.forEach(in: file) { line, _ in
                    guard line.range(of: Self.tokenCount) != nil || line.range(of: Self.turnContext) != nil,
                          let entry = JSONLines.object(line) else { return }
                    if entry["type"] as? String == "turn_context" {
                        let payload = entry["payload"] as? [String: Any] ?? [:]
                        model = Self.modelName(PyNumber.truthyString(payload["model"]) ?? PyNumber.truthyString(payload["model_slug"]) ?? model)
                        return
                    }
                    var payload: Any = Self.truthy(entry["payload"]) ?? entry
                    if entry["type"] as? String == "response_item", let inner = payload as? [String: Any] {
                        payload = Self.truthy(inner["payload"]) ?? inner
                    }
                    guard let body = payload as? [String: Any], body["type"] as? String == "token_count" else { return }
                    let info = body["info"] as? [String: Any] ?? [:]
                    let usage = info["last_token_usage"] as? [String: Any] ?? [:]
                    let cacheRead = PyNumber.truncated(usage["cached_input_tokens"])
                    let cacheWrite = PyNumber.truncated(usage["cache_write_input_tokens"])
                    let input = max(0, PyNumber.truncated(usage["input_tokens"]) - cacheRead - cacheWrite)
                    let output = PyNumber.truncated(usage["output_tokens"])
                    guard input != 0 || output != 0 || cacheRead != 0 || cacheWrite != 0 else { return }
                    let day = LocalDay.from(
                        Self.truthy(entry["timestamp"]) ?? NSNumber(value: modified.timeIntervalSince1970),
                        now: now, calendar: calendar
                    )
                    tally.add(day: day, session: path, model: model, input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
                }
            }
        }
    }

    // MARK: - pi and omp

    private static let openAICodex = Data("openai-codex".utf8)

    /// `scan_pi_sessions`: messages a pi or omp session sent through `openai-codex`.
    private func scanPiSessions(now: Date, into tally: inout StatsAccumulator) {
        var seen: Set<String> = []
        for root in piSessionRoots {
            for file in JSONLines.files(under: root) {
                let path = file.path(percentEncoded: false)
                JSONLines.forEach(in: file) { line, _ in
                    guard line.range(of: Self.openAICodex) != nil, let entry = JSONLines.object(line),
                          entry["type"] as? String == "message" else { return }
                    guard seen.insert(path + ":" + (PyNumber.truthyString(entry["id"]) ?? "")).inserted else { return }
                    let message = entry["message"] as? [String: Any] ?? [:]
                    guard message["role"] as? String == "assistant" else { return }
                    let provider = PyNumber.truthyString(message["provider"]) ?? ""
                    let api = PyNumber.truthyString(message["api"]) ?? ""
                    guard provider == "openai-codex" || api.hasPrefix("openai-codex") else { return }
                    guard let usage = message["usage"] as? [String: Any], !usage.isEmpty else { return }
                    let total = PyNumber.truncated(usage["totalTokens"])
                    var input = PyNumber.truncated(usage["input"])
                    let output = PyNumber.truncated(usage["output"])
                    let cacheRead = PyNumber.truncated(usage["cacheRead"])
                    let cacheWrite = PyNumber.truncated(usage["cacheWrite"])
                    if total != 0, input == 0, output == 0, cacheRead == 0, cacheWrite == 0 { input = total }
                    guard input != 0 || output != 0 || cacheRead != 0 || cacheWrite != 0 else { return }
                    tally.add(
                        day: LocalDay.from(Self.truthy(entry["timestamp"]) ?? message["timestamp"], now: now, calendar: calendar),
                        session: path, model: Self.modelName(message["model"]),
                        input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite
                    )
                }
            }
        }
    }

    // MARK: - opencode

    /// The query omarchy-agent-usage-codex runs. The LIKE gates skip rows that can't match before
    /// any JSON parse; `json_valid` keeps one malformed row from aborting the scan.
    private static let opencodeQuery = """
        SELECT session_id, data FROM message
         WHERE data LIKE '%"role"%:%"assistant"%'
         AND data LIKE '%"providerID"%:%"openai"%'
         AND CASE WHEN json_valid(data) THEN json_extract(data, '$.role') END = 'assistant'
         AND CASE WHEN json_valid(data) THEN json_extract(data, '$.providerID') END = 'openai'
        """

    /// `scan_opencode_sessions`: OpenAI-provider messages from opencode's database, opened
    /// read-only. Returns whether the scan ran to completion.
    private func scanOpencode(now: Date, into tally: inout StatsAccumulator) -> Bool {
        let path = opencodeDatabase.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return true }
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            sqlite3_close(database)
            return false
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2000)
        sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, Self.opencodeQuery, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }

        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return true }
            // Transient lock, schema migration, corruption: the numbers stop here, incomplete.
            guard step == SQLITE_ROW else { return false }
            guard let bytes = sqlite3_column_blob(statement, 1) else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
            guard let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  entry["role"] as? String == "assistant",
                  // Exact match: a custom "openai-local" gateway is not this subscription.
                  entry["providerID"] as? String == "openai" else { continue }
            let tokens = entry["tokens"] as? [String: Any] ?? [:]
            let cache = tokens["cache"] as? [String: Any] ?? [:]
            let input = PyNumber.truncated(tokens["input"])
            // opencode keeps thinking tokens out of output; both are generated.
            let output = PyNumber.truncated(tokens["output"]) + PyNumber.truncated(tokens["reasoning"])
            let cacheRead = PyNumber.truncated(cache["read"])
            let cacheWrite = PyNumber.truncated(cache["write"])
            guard input != 0 || output != 0 || cacheRead != 0 || cacheWrite != 0 else { continue }
            let day = LocalDay.from((entry["time"] as? [String: Any])?["created"], now: now, calendar: calendar)
            let model = Self.modelName(OpencodeModel.lastSegment(PyNumber.truthyString(entry["modelID"]) ?? ""))
            let session = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "None"
            tally.add(day: day, session: "opencode:" + session, model: model, input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
        }
    }

    // MARK: - Helpers

    /// `model_name`: whatever was given, or "codex".
    static func modelName(_ raw: Any?) -> String {
        let name = PyNumber.truthyString(raw) ?? "codex"
        return name.isEmpty ? "codex" : name
    }

    private static func truthy(_ value: Any?) -> Any? {
        switch value {
        case let string as String: return string.isEmpty ? nil : string
        case let number as NSNumber: return number == 0 ? nil : number
        case let dictionary as [String: Any]: return dictionary.isEmpty ? nil : dictionary
        case is NSNull: return nil
        default: return value
        }
    }

    // MARK: - Cache

    struct ScanCache: Codable {
        var schemaVersion: Int
        var scanDate: String
        var scannedAtMs: Double
        var stats: LocalStats
    }

    var cacheURL: URL { cacheDirectory.appending(path: "codex-local.json") }

    private func readCache() -> ScanCache? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(ScanCache.self, from: data)
    }

    private func writeCache(_ cache: ScanCache) {
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
        } catch {
            Logger.collector.error("Couldn't write the Codex scan cache: \(String(describing: error), privacy: .public)")
        }
    }
}

/// opencode model ids are provider paths (`accounts/fireworks/models/kimi-k2`); the collectors
/// keep the last segment: `str(modelID).rstrip("/").split("/")[-1]`.
enum OpencodeModel {
    static func lastSegment(_ raw: String) -> String {
        var trimmed = Substring(raw)
        while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        return trimmed.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    }
}
