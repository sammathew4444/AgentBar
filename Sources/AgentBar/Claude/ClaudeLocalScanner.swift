import Foundation
import OSLog
import SQLite3

/// Claude Code usage on this machine, gathered as omarchy-agent-usage-claude does: native
/// transcripts under `projects/`, falling back to `stats-cache.json` and then `history.jsonl`,
/// plus the sessions pi, omp and opencode ran on an Anthropic provider. Everything here is
/// read-only and local; nothing is written anywhere but AgentBar's own cache.
struct ClaudeLocalScanner: Sendable {
    /// `cache_seconds` default: dedups overlapping runs without skipping a real rescan.
    static let scanReuse: TimeInterval = 20
    /// `--limits-only` (a panel opening) promises fresh limits only, so a scan may be this old.
    static let limitsOnlyReuse: TimeInterval = 900

    /// `$CLAUDE_CONFIG_DIR`, default `~/.claude`.
    let claudeDirectory: URL
    /// `~/.pi/agent/sessions` and `~/.omp/agent/sessions`.
    let piSessionRoots: [URL]
    /// `$XDG_DATA_HOME/opencode/opencode.db`, default under `~/.local/share`.
    let opencodeDatabase: URL
    let cacheDirectory: URL
    let calendar: Calendar

    static func live(cacheDirectory: URL) -> ClaudeLocalScanner {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        func directory(_ variable: String) -> URL? {
            guard let value = environment[variable], !value.isEmpty else { return nil }
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
        }
        let dataHome = directory("XDG_DATA_HOME") ?? home.appending(path: ".local/share", directoryHint: .isDirectory)
        return ClaudeLocalScanner(
            claudeDirectory: directory("CLAUDE_CONFIG_DIR") ?? home.appending(path: ".claude", directoryHint: .isDirectory),
            piSessionRoots: [
                home.appending(path: ".pi/agent/sessions", directoryHint: .isDirectory),
                home.appending(path: ".omp/agent/sessions", directoryHint: .isDirectory),
            ],
            opencodeDatabase: dataHome.appending(path: "opencode/opencode.db"),
            cacheDirectory: cacheDirectory,
            calendar: .current
        )
    }

    /// Off the cooperative pool: a first scan of a large history takes a moment.
    func stats(now: Date, maxAge: TimeInterval) async -> LocalStats {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: statsBlocking(now: now, maxAge: maxAge))
            }
        }
    }

    /// Reused while younger than `maxAge` and scanned on the same local day, since today's
    /// counts only mean "today" on the day they were taken.
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

    /// `main()`'s local half.
    func scanAll(now: Date) -> LocalStats {
        var stats = scanProjects(now: now)
        if stats.totalPrompts <= 0 {
            if let fallback = statsCacheFallback(now: now) {
                stats = fallback
            } else {
                // No transcripts and no aggregate cache, but history.jsonl alone can put numbers on today.
                let (prompts, sessions) = todayPromptsFromHistory(now: now)
                if prompts > 0 || sessions > 0 {
                    stats.todayPrompts = prompts
                    stats.todaySessions = sessions
                }
            }
        }
        if let pi = scanPiSessions(now: now) { stats = stats.merged(with: pi) }
        if let opencode = scanOpencode(now: now) { stats = stats.merged(with: opencode) }
        return stats
    }

    // MARK: - Transcripts

    private static let usageNeedle = Data(#""usage":"#.utf8)

    /// `scan_projects`: each API message counts once, however many transcript lines repeat it.
    func scanProjects(now: Date) -> LocalStats {
        var tally = StatsAccumulator(now: now, calendar: calendar)
        var seen: Set<String> = []
        for file in JSONLines.files(under: claudeDirectory.appending(path: "projects", directoryHint: .isDirectory)) {
            let path = file.path(percentEncoded: false)
            JSONLines.forEach(in: file) { line, lineNumber in
                // Cheap pre-filter before JSON parsing keeps unrelated lines inexpensive.
                guard line.range(of: Self.usageNeedle) != nil, let entry = JSONLines.object(line) else { return }
                let message = entry["message"] as? [String: Any] ?? [:]
                guard entry["type"] as? String == "assistant" || message["role"] as? String == "assistant" else { return }
                let rawUsage = (message["usage"] as? [String: Any]).flatMap { $0.isEmpty ? nil : $0 } ?? entry["usage"]
                guard let usage = rawUsage as? [String: Any] else { return }

                let messageID = PyNumber.truthyString(message["id"]) ?? PyNumber.truthyString(entry["messageId"])
                let key = messageID ?? "\(path):\(PyNumber.truthyString(entry["uuid"]) ?? PyNumber.truthyString(entry["requestId"]) ?? String(lineNumber))"
                guard seen.insert(key).inserted else { return }

                let input = Self.usageToken(usage, "input_tokens", "inputTokens")
                let output = Self.usageToken(usage, "output_tokens", "outputTokens")
                let cacheRead = Self.usageToken(usage, "cache_read_input_tokens", "cacheReadInputTokens")
                let cacheWrite = Self.usageToken(usage, "cache_creation_input_tokens", "cacheCreationInputTokens")
                guard input + output + cacheRead + cacheWrite > 0 else { return }

                tally.add(
                    day: LocalDay.from(Self.truthy(entry["timestamp"]) ?? message["timestamp"], now: now, calendar: calendar),
                    session: PyNumber.truthyString(entry["sessionId"]) ?? path,
                    model: PyNumber.truthyString(message["model"]) ?? PyNumber.truthyString(entry["model"]) ?? "claude",
                    input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite
                )
            }
        }
        return tally.stats
    }

    /// `usage_token`: the snake-case key wins whenever it is present, even as null.
    static func usageToken(_ usage: [String: Any], _ snake: String, _ camel: String) -> Int {
        PyNumber.rounded(usage.keys.contains(snake) ? usage[snake] : usage[camel])
    }

    // MARK: - Fallbacks

    /// Claude Code's own aggregate counters, for a machine without transcripts on disk.
    func statsCacheFallback(now: Date) -> LocalStats? {
        guard let data = try? Data(contentsOf: claudeDirectory.appending(path: "stats-cache.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let today = LocalDay.string(now, calendar: calendar)

        var todayTokens: [String: Int] = [:]
        for case let entry as [String: Any] in root["dailyModelTokens"] as? [Any] ?? [] where entry["date"] as? String == today {
            for (model, count) in entry["tokensByModel"] as? [String: Any] ?? [:] {
                todayTokens[model] = PyNumber.rounded(count)
            }
            break
        }

        let dailyActivity = (root["dailyActivity"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let activeDates = Set(dailyActivity.compactMap { day -> String? in
            guard PyNumber.rounded(day["messageCount"]) > 0 else { return nil }
            return PyNumber.truthyString(day["date"])
        }).sorted()
        var modelUsage: [String: UsageRecord.TokenBucket] = [:]
        for (model, value) in root["modelUsage"] as? [String: Any] ?? [:] {
            let bucket = value as? [String: Any] ?? [:]
            modelUsage[model] = .init(
                inputTokens: PyNumber.rounded(bucket["inputTokens"]),
                outputTokens: PyNumber.rounded(bucket["outputTokens"]),
                cacheReadInputTokens: PyNumber.rounded(bucket["cacheReadInputTokens"]),
                cacheCreationInputTokens: PyNumber.rounded(bucket["cacheCreationInputTokens"])
            )
        }
        let (prompts, sessions) = todayPromptsFromHistory(now: now)

        return LocalStats(
            todayPrompts: prompts,
            todaySessions: sessions,
            todayTotalTokens: todayTokens.values.reduce(0, +),
            todayTokensByModel: todayTokens,
            recentDays: dailyActivity.suffix(7).map {
                .init(date: ($0["date"] as? String) ?? "", messageCount: PyNumber.rounded($0["messageCount"]))
            },
            modelUsage: modelUsage,
            totalPrompts: PyNumber.rounded(root["totalMessages"]),
            totalSessions: PyNumber.rounded(root["totalSessions"]),
            activeDays: activeDates.count,
            activeDates: activeDates
        )
    }

    /// `today_prompts_from_history`: newest first, stopping at the first entry before today.
    func todayPromptsFromHistory(now: Date) -> (prompts: Int, sessions: Int) {
        guard let data = try? Data(contentsOf: claudeDirectory.appending(path: "history.jsonl")) else { return (0, 0) }
        let startOfDay = calendar.startOfDay(for: now).timeIntervalSince1970 * 1000
        var prompts = 0
        var sessions: Set<String> = []
        for line in data.split(separator: 0x0A).reversed() {
            guard let entry = JSONLines.object(line) else { continue }
            if Double(PyNumber.rounded(entry["timestamp"])) < startOfDay { break }
            prompts += 1
            if let session = PyNumber.truthyString(entry["sessionId"]) { sessions.insert(session) }
        }
        return (prompts, sessions.count)
    }

    // MARK: - pi and omp

    private static let quotedUsage = Data(#""usage""#.utf8)
    private static let quotedAssistant = Data(#""assistant""#.utf8)

    /// `scan_pi_usage`: pi and omp can spend a Claude subscription without writing Claude Code
    /// transcripts. Only the `anthropic` provider counts.
    func scanPiSessions(now: Date) -> LocalStats? {
        var tally = StatsAccumulator(now: now, calendar: calendar)
        var seen: Set<String> = []
        for root in piSessionRoots {
            for file in JSONLines.files(under: root) {
                let path = file.path(percentEncoded: false)
                JSONLines.forEach(in: file) { line, lineNumber in
                    guard line.range(of: Self.quotedUsage) != nil, line.range(of: Self.quotedAssistant) != nil,
                          let entry = JSONLines.object(line), let message = entry["message"] as? [String: Any],
                          entry["type"] as? String == "message", message["role"] as? String == "assistant",
                          message["provider"] as? String == "anthropic" else { return }
                    guard seen.insert("\(path):\(PyNumber.truthyString(entry["id"]) ?? String(lineNumber))").inserted else { return }
                    let usage = message["usage"] as? [String: Any] ?? [:]
                    var input = Self.usageToken(usage, "input", "inputTokens")
                    let output = Self.usageToken(usage, "output", "outputTokens")
                    let cacheRead = Self.usageToken(usage, "cacheRead", "cache_read_input_tokens")
                    let cacheWrite = Self.usageToken(usage, "cacheWrite", "cache_creation_input_tokens")
                    if input + output + cacheRead + cacheWrite <= 0 {
                        input = PyNumber.rounded(usage["totalTokens"])
                    }
                    guard input + output + cacheRead + cacheWrite > 0 else { return }
                    tally.add(
                        day: LocalDay.from(Self.truthy(entry["timestamp"]) ?? message["timestamp"], now: now, calendar: calendar),
                        session: path,
                        model: PyNumber.truthyString(message["model"]) ?? "claude",
                        input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite
                    )
                }
            }
        }
        return tally.prompts > 0 ? tally.stats : nil
    }

    // MARK: - opencode

    /// `scan_opencode_usage`: opencode records per-message provider, model and tokens in its
    /// own database. Opened read-only, as opencode may be writing to it.
    func scanOpencode(now: Date) -> LocalStats? {
        let path = opencodeDatabase.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2000)
        sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT session_id, data FROM message", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        let today = LocalDay.string(now, calendar: calendar)
        let needle = Data("anthropic".utf8)
        var tally = StatsAccumulator(now: now, calendar: calendar)
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            // A lock or corruption mid-scan: the numbers would be incomplete, so there are none.
            guard step == SQLITE_ROW else { return nil }
            guard let bytes = sqlite3_column_blob(statement, 1) else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
            // Pure acceleration: a row without the word can't be an Anthropic message.
            guard data.range(of: needle) != nil,
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  entry["role"] as? String == "assistant",
                  // Exact match: a custom "anthropic-proxy" gateway is not this subscription.
                  entry["providerID"] as? String == "anthropic",
                  let tokens = entry["tokens"] as? [String: Any] else { continue }
            let cache = tokens["cache"] as? [String: Any] ?? [:]
            let input = PyNumber.rounded(tokens["input"])
            // opencode keeps thinking tokens out of output; both are generated.
            let output = PyNumber.rounded(tokens["output"]) + PyNumber.rounded(tokens["reasoning"])
            let cacheRead = PyNumber.rounded(cache["read"])
            let cacheWrite = PyNumber.rounded(cache["write"])
            guard input + output + cacheRead + cacheWrite > 0 else { continue }

            let created = PyNumber.rounded((entry["time"] as? [String: Any])?["created"])
            let day = created > 0 ? LocalDay.string(Date(timeIntervalSince1970: Double(created) / 1000), calendar: calendar) : today
            let rawModel = PyNumber.truthyString(entry["modelID"]) ?? "claude"
            let model = String(rawModel.reversed().drop { $0 == "/" }.reversed()).split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? rawModel
            let session = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "None"
            tally.add(day: day, session: "opencode:" + session, model: model, input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
        }
        return tally.prompts > 0 ? tally.stats : nil
    }

    // MARK: - Cache

    struct ScanCache: Codable {
        var scanDate: String
        var scannedAtMs: Double
        var stats: LocalStats
    }

    var cacheURL: URL { cacheDirectory.appending(path: "claude-local.json") }

    private func readCache() -> ScanCache? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(ScanCache.self, from: data)
    }

    private func writeCache(_ cache: ScanCache) {
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
        } catch {
            Logger.collector.error("Couldn't write the local scan cache: \(String(describing: error), privacy: .public)")
        }
    }

    /// Python's `a or b` for a timestamp: an empty string or zero falls through.
    private static func truthy(_ value: Any?) -> Any? {
        switch value {
        case let string as String: return string.isEmpty ? nil : string
        case let number as NSNumber: return number == 0 ? nil : number
        case is NSNull: return nil
        default: return value
        }
    }
}
