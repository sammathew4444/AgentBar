import Foundation
import SQLite3
import Testing
@testable import AgentBar

/// Cases from Omarchy's test/shell.d/agent-usage-claude-scanner-test.sh, run against the
/// committed fixtures in Fixtures/local with a fixed clock, so every number is reproducible.
@Suite("Claude local scan")
struct ClaudeLocalScannerTests {
    /// 2026-09-14T15:00:00Z; the fixture timestamps sit around it.
    static let now = Date(timeIntervalSince1970: 1_789_398_000)
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static let local = TestPaths.fixtures.appending(path: "local", directoryHint: .isDirectory)

    private func scanner(claude: String = "missing", pi: [String] = [], opencode: URL? = nil, cache: URL) -> ClaudeLocalScanner {
        ClaudeLocalScanner(
            claudeDirectory: Self.local.appending(path: claude, directoryHint: .isDirectory),
            piSessionRoots: pi.map { Self.local.appending(path: $0, directoryHint: .isDirectory) },
            opencodeDatabase: opencode ?? Self.local.appending(path: "missing/opencode.db"),
            cacheDirectory: cache,
            calendar: Self.utc
        )
    }

    @Test("Each API message counts once, and the token categories stay exclusive")
    func transcripts() throws {
        let temp = try TemporaryDirectory()
        let stats = scanner(claude: "claude", cache: temp.url).scanAll(now: Self.now)

        #expect(stats.todayTotalTokens == 58793)
        #expect(stats.modelUsage["claude-test"] == .init(inputTokens: 4, outputTokens: 621, cacheReadInputTokens: 28857, cacheCreationInputTokens: 29311))
        #expect(stats.todayPrompts == 2)
        #expect(stats.todaySessions == 1)
        #expect(stats.todayTokensByModel == ["claude-test": 58793])
    }

    @Test("The week, all-time totals and active days come from every transcript")
    func weekAndAllTime() throws {
        let temp = try TemporaryDirectory()
        let stats = scanner(claude: "claude", cache: temp.url).scanAll(now: Self.now)

        #expect(stats.recentDays == [
            .init(date: "2026-09-08", messageCount: 0),
            .init(date: "2026-09-09", messageCount: 0),
            .init(date: "2026-09-10", messageCount: 150),
            .init(date: "2026-09-11", messageCount: 0),
            .init(date: "2026-09-12", messageCount: 0),
            .init(date: "2026-09-13", messageCount: 0),
            .init(date: "2026-09-14", messageCount: 58793),
        ])
        // The zero-token message is dropped; the one outside the week still counts all-time.
        #expect(stats.modelUsage["claude-older"] == .init(inputTokens: 110, outputTokens: 55))
        #expect(stats.totalPrompts == 4)
        #expect(stats.totalSessions == 2)
        #expect(stats.activeDates == ["2026-08-01", "2026-09-10", "2026-09-14"])
        #expect(stats.activeDays == 3)
    }

    @Test("Without transcripts or a stats-cache, history.jsonl still counts today")
    func historyFallback() throws {
        let temp = try TemporaryDirectory()
        let stats = scanner(claude: "history", cache: temp.url).scanAll(now: Self.now)
        #expect(stats.todayPrompts == 2)
        #expect(stats.todaySessions == 2)
        #expect(stats.totalPrompts == 0)
        #expect(stats.recentDays.count == 7)
    }

    @Test("Without transcripts, Claude Code's stats-cache stands in")
    func statsCacheFallback() throws {
        let temp = try TemporaryDirectory()
        let stats = scanner(claude: "stats-cache", cache: temp.url).scanAll(now: Self.now)
        #expect(stats.todayTotalTokens == 1500)
        #expect(stats.todayTokensByModel == ["claude-opus-5": 1200, "claude-haiku-4-5": 300])
        #expect(stats.recentDays.map(\.date) == ["2026-09-12", "2026-09-13", "2026-09-14"])
        #expect(stats.activeDates == ["2026-09-12", "2026-09-14"])
        #expect(stats.totalPrompts == 120)
        #expect(stats.totalSessions == 9)
        #expect(stats.modelUsage["claude-opus-5"] == .init(inputTokens: 1000, outputTokens: 400, cacheReadInputTokens: 20000, cacheCreationInputTokens: 3000))
    }

    @Test("pi and omp sessions count when they ran on Anthropic")
    func piAndOmp() throws {
        let temp = try TemporaryDirectory()
        let stats = scanner(pi: ["pi/sessions", "omp/sessions"], cache: temp.url).scanAll(now: Self.now)
        #expect(stats.todayTotalTokens == 49)
        #expect(stats.modelUsage == [
            "claude-omp": .init(inputTokens: 20, outputTokens: 5, cacheReadInputTokens: 4, cacheCreationInputTokens: 1),
            "claude-pi": .init(inputTokens: 10, outputTokens: 4, cacheReadInputTokens: 3, cacheCreationInputTokens: 2),
        ])
    }

    @Test("Transcripts and pi sessions merge")
    func merged() throws {
        let temp = try TemporaryDirectory()
        let stats = scanner(claude: "claude", pi: ["pi/sessions", "omp/sessions"], cache: temp.url).scanAll(now: Self.now)
        #expect(stats.todayTotalTokens == 58793 + 49)
        #expect(stats.totalPrompts == 6)
        #expect(stats.recentDays.last == .init(date: "2026-09-14", messageCount: 58793 + 49))
        #expect(stats.modelUsage.keys.sorted() == ["claude-older", "claude-omp", "claude-pi", "claude-test"])
    }

    @Test("opencode's Anthropic messages count, reasoning included; other providers and bad rows don't")
    func opencode() throws {
        let temp = try TemporaryDirectory()
        let database = temp.url.appending(path: "opencode.db")
        try makeOpencodeDatabase(at: database)
        let stats = scanner(opencode: database, cache: temp.url).scanAll(now: Self.now)
        #expect(stats.todayTotalTokens == 192)
        #expect(stats.modelUsage == ["claude-opus-5": .init(inputTokens: 100, outputTokens: 57, cacheReadInputTokens: 25, cacheCreationInputTokens: 10)])
    }

    @Test("A scan is reused inside its window on the same day, and redone otherwise")
    func cache() throws {
        let temp = try TemporaryDirectory()
        let projects = temp.url.appending(path: "claude/projects/p", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let transcript = projects.appending(path: "s.jsonl")
        func line(_ id: String) -> String {
            #"{"timestamp":"2026-09-14T12:00:00Z","type":"assistant","sessionId":"s","message":{"id":"\#(id)","role":"assistant","model":"m","usage":{"input_tokens":1}}}"# + "\n"
        }
        try line("a").write(to: transcript, atomically: true, encoding: .utf8)
        let scanner = ClaudeLocalScanner(
            claudeDirectory: temp.url.appending(path: "claude"), piSessionRoots: [],
            opencodeDatabase: temp.url.appending(path: "none.db"), cacheDirectory: temp.url.appending(path: "cache"), calendar: Self.utc
        )

        #expect(scanner.statsBlocking(now: Self.now, maxAge: 20).totalPrompts == 1)
        try (line("a") + line("b")).write(to: transcript, atomically: true, encoding: .utf8)
        #expect(scanner.statsBlocking(now: Self.now.addingTimeInterval(10), maxAge: 20).totalPrompts == 1)
        #expect(scanner.statsBlocking(now: Self.now.addingTimeInterval(10), maxAge: 0).totalPrompts == 2)
        try (line("a") + line("b") + line("c")).write(to: transcript, atomically: true, encoding: .utf8)
        // A new day invalidates today's counts whatever the window says.
        #expect(scanner.statsBlocking(now: Self.now.addingTimeInterval(12 * 3600), maxAge: 900_000).totalPrompts == 3)
    }

    @Test("Local days from each timestamp shape")
    func localDays() {
        var istanbul = Calendar(identifier: .gregorian)
        istanbul.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        #expect(LocalDay.from("2026-09-14T22:30:00Z", now: Self.now, calendar: istanbul) == "2026-09-15")
        #expect(LocalDay.from("2026-09-14T23:30:00", now: Self.now, calendar: istanbul) == "2026-09-14")
        #expect(LocalDay.from(NSNumber(value: 1_789_398_000_000), now: Self.now, calendar: Self.utc) == "2026-09-14")
        #expect(LocalDay.from(NSNumber(value: 1_789_398_000), now: Self.now, calendar: Self.utc) == "2026-09-14")
        #expect(LocalDay.from("yesterday", now: Self.now, calendar: Self.utc) == "2026-09-14")
        #expect(LocalDay.from(nil, now: Self.now, calendar: Self.utc) == "2026-09-14")
    }

    @Test("Numbers are read the way Python reads them")
    func numbers() {
        #expect(PyNumber.rounded(2.5) == 2)
        #expect(PyNumber.rounded(3.5) == 4)
        #expect(PyNumber.rounded("12") == 12)
        #expect(PyNumber.rounded(nil) == 0)
        #expect(PyNumber.rounded(Double.nan) == 0)
        #expect(PyNumber.truncated(3.9) == 3)
        #expect(PyNumber.truncated("3.5") == 0)
    }

    /// The port of the Omarchy test's opencode fixture.
    private func makeOpencodeDatabase(at url: URL) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path(percentEncoded: false), &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let created = 1_789_390_800_000 // 2026-09-14T13:00:00Z
        func message(_ id: String, _ provider: String, _ model: String, role: String = "assistant",
                     input: Int = 0, output: Int = 0, reasoning: Int = 0, read: Int = 0, write: Int = 0) -> String {
            let data = #"{"role":"\#(role)","providerID":"\#(provider)","modelID":"\#(model)","tokens":{"input":\#(input),"output":\#(output),"reasoning":\#(reasoning),"cache":{"read":\#(read),"write":\#(write)}},"time":{"created":\#(created)}}"#
            return "INSERT INTO message VALUES ('\(id)', 'ses_1', \(created), \(created), '\(data)');"
        }
        let sql = [
            "CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);",
            message("msg_1", "anthropic", "claude-opus-5", input: 100, output: 50, reasoning: 7, read: 25, write: 10),
            message("msg_2", "fireworks-ai", "accounts/fireworks/models/kimi-k3", input: 999, output: 999),
            message("msg_3", "openai", "gpt-5.2-codex", input: 999, output: 999),
            message("msg_4", "anthropic", "claude-opus-5", role: "user"),
            message("msg_5", "anthropic-proxy", "claude-opus-5", input: 999, output: 999),
            "INSERT INTO message VALUES ('msg_6', 'ses_1', \(created), \(created), '[\"not\",\"an\",\"object\"]');",
        ].joined(separator: "\n")
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }
}
