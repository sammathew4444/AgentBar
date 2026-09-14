import Foundation
import Testing
@testable import AgentBar

/// Cases from Omarchy's test/shell.d/agent-usage-codex-scanner-test.sh, on the committed fixtures
/// in Fixtures/local with a fixed clock. `Fixtures/local/codex-bin/codex` stands in for the
/// app-server; nothing here runs the real Codex or touches the network.
@Suite("Codex collector")
struct CodexCollectorTests {
    static let now = ClaudeLocalScannerTests.now
    static let utc = ClaudeLocalScannerTests.utc
    static let local = ClaudeLocalScannerTests.local
    static let fakeCodex = local.appending(path: "codex-bin", directoryHint: .isDirectory)

    private func scanner(home: URL? = nil, pi: [String] = [], opencode: URL? = nil, cache: URL) -> CodexLocalScanner {
        CodexLocalScanner(
            codexHome: home ?? Self.local.appending(path: "missing", directoryHint: .isDirectory),
            piSessionRoots: pi.map { Self.local.appending(path: $0, directoryHint: .isDirectory) },
            opencodeDatabase: opencode ?? Self.local.appending(path: "missing/opencode.db"),
            cacheDirectory: cache,
            calendar: Self.utc
        )
    }

    private func appServer(_ environment: [String: String] = [:], searchPath: [String]? = nil, timeout: TimeInterval = 4) -> CodexAppServer {
        var server = CodexAppServer(
            searchPath: searchPath ?? [Self.fakeCodex.path(percentEncoded: false)],
            environment: environment.merging(["PATH": "/usr/bin:/bin"]) { current, _ in current }
        )
        server.initializeTimeout = timeout
        server.requestTimeout = timeout
        return server
    }

    // MARK: - Native sessions

    @Test("Each turn counts once, and cache and reasoning aren't counted twice")
    func nativeSessions() throws {
        let temp = try TemporaryDirectory()
        let stats = scanner(home: Self.local.appending(path: "codex"), cache: temp.url).scanAll(now: Self.now).stats
        #expect(stats.todayTotalTokens == 210)
        #expect(stats.modelUsage["gpt-test"] == .init(inputTokens: 70, outputTokens: 30, cacheReadInputTokens: 110, cacheCreationInputTokens: 0))
        #expect(stats.todayPrompts == 2)
        #expect(stats.todaySessions == 1)
    }

    @Test("Session files untouched for 30 days are left out")
    func sessionWindow() throws {
        let temp = try TemporaryDirectory()
        let sessions = temp.url.appending(path: "codex/sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let line = #"{"timestamp":"2026-09-14T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":5,"output_tokens":1}}}}"#
        for (name, age) in [("recent", 29.0), ("stale", 31.0)] {
            let file = sessions.appending(path: "\(name).jsonl")
            try line.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Self.now.addingTimeInterval(-age * 86_400)], ofItemAtPath: file.path(percentEncoded: false))
        }
        let stats = scanner(home: temp.url.appending(path: "codex"), cache: temp.url).scanAll(now: Self.now).stats
        #expect(stats.totalPrompts == 1)
        #expect(stats.todayTotalTokens == 6)
    }

    // MARK: - pi, omp, opencode

    @Test("pi and omp sessions count when they ran through openai-codex")
    func piAndOmp() throws {
        let temp = try TemporaryDirectory()
        let stats = scanner(pi: ["codex-pi/sessions", "codex-omp/sessions"], cache: temp.url).scanAll(now: Self.now).stats
        #expect(stats.todayTotalTokens == 49)
        #expect(stats.modelUsage == [
            "gpt-pi": .init(inputTokens: 10, outputTokens: 4, cacheReadInputTokens: 3, cacheCreationInputTokens: 2),
            "gpt-omp": .init(inputTokens: 20, outputTokens: 5, cacheReadInputTokens: 4, cacheCreationInputTokens: 1),
        ])
    }

    @Test("opencode's OpenAI messages count, reasoning included; other providers and bad rows don't")
    func opencode() throws {
        let temp = try TemporaryDirectory()
        let db = temp.url.appending(path: "opencode.db")
        try OpencodeFixture.create(at: db)
        try OpencodeFixture.insert(at: db, [
            ("msg_1", OpencodeFixture.message("msg_1", "openai", "gpt-5.2-codex", input: 80, output: 40, reasoning: 5, read: 30)),
            ("msg_2", OpencodeFixture.message("msg_2", "anthropic", "claude-opus-5", input: 999, output: 999)),
            ("msg_3", OpencodeFixture.message("msg_3", "openai", "gpt-5.2-codex", role: "user")),
            ("msg_4", OpencodeFixture.message("msg_4", "openai-local", "gpt-5.2-codex", input: 999, output: 999)),
            ("msg_5", #"["not","an","object"]"#),
        ])
        let stats = scanner(opencode: db, cache: temp.url).scanAll(now: Self.now).stats
        #expect(stats.todayTotalTokens == 155)
        #expect(stats.modelUsage == ["gpt-5.2-codex": .init(inputTokens: 80, outputTokens: 45, cacheReadInputTokens: 30, cacheCreationInputTokens: 0)])
    }

    @Test("Good opencode rows count past malformed ones")
    func malformedRows() throws {
        let temp = try TemporaryDirectory()
        let db = temp.url.appending(path: "opencode.db")
        try OpencodeFixture.create(at: db)
        try OpencodeFixture.insert(at: db, [
            ("mm_1", OpencodeFixture.message("mm_1", "openai", "gpt-5.2-codex", input: 5)),
            ("mm_2", OpencodeFixture.message("mm_2", "openai", "gpt-5.2-codex", input: 7)),
            ("mm_3", OpencodeFixture.message("mm_3", "openai", "gpt-5.2-codex", input: 999) + " trailing-garbage"),
            ("mm_4", "this is not json"),
        ])
        #expect(scanner(opencode: db, cache: temp.url).scanAll(now: Self.now).stats.todayTotalTokens == 12)
    }

    // MARK: - Cache

    @Test("The cache is reused inside its window, and missed on another day, in the future, or when forced")
    func cache() throws {
        let temp = try TemporaryDirectory()
        let db = temp.url.appending(path: "opencode.db")
        try OpencodeFixture.create(at: db)
        func add(_ id: String, _ input: Int) throws {
            try OpencodeFixture.insert(at: db, [(id, OpencodeFixture.message(id, "openai", "gpt-5.2-codex", input: input))])
        }
        let scanner = scanner(opencode: db, cache: temp.url.appending(path: "cache"))
        func today(_ now: Date, _ maxAge: TimeInterval) -> Int { scanner.statsBlocking(now: now, maxAge: maxAge).todayTotalTokens }

        try add("c_1", 5)
        #expect(today(Self.now, CodexLocalScanner.scanReuse) == 5)
        try add("c_2", 10)
        #expect(today(Self.now.addingTimeInterval(60), CodexLocalScanner.limitsOnlyReuse) == 5)
        #expect(today(Self.now.addingTimeInterval(60), 0) == 15)
        try add("c_3", 10)
        // Past the no-flag window, inside the panel-open one.
        #expect(today(Self.now.addingTimeInterval(90), CodexLocalScanner.scanReuse) == 25)
        try add("c_4", 10)
        #expect(today(Self.now.addingTimeInterval(600), CodexLocalScanner.limitsOnlyReuse) == 25)
        // A cache written "later" than now has no trustworthy age.
        #expect(today(Self.now.addingTimeInterval(30), CodexLocalScanner.limitsOnlyReuse) == 35)
        try add("c_5", 10)
        // Another local day turns any cache into a miss (the row's own day is still the 14th).
        #expect(scanner.statsBlocking(now: Self.now.addingTimeInterval(86_400), maxAge: 1e9).totalPrompts == 5)
    }

    @Test("A scan cut short by a database error isn't cached")
    func interruptedScan() throws {
        let temp = try TemporaryDirectory()
        let db = temp.url.appending(path: "opencode.db")
        try OpencodeFixture.create(at: db, table: false)
        let scanner = scanner(opencode: db, cache: temp.url.appending(path: "cache"))

        #expect(scanner.statsBlocking(now: Self.now, maxAge: CodexLocalScanner.scanReuse).todayTotalTokens == 0)
        #expect(!FileManager.default.fileExists(atPath: scanner.cacheURL.path(percentEncoded: false)))

        try OpencodeFixture.create(at: db)
        try OpencodeFixture.insert(at: db, [("i_1", OpencodeFixture.message("i_1", "openai", "gpt-5.2-codex", input: 9))])
        #expect(scanner.statsBlocking(now: Self.now.addingTimeInterval(5), maxAge: CodexLocalScanner.limitsOnlyReuse).todayTotalTokens == 9)
    }

    // MARK: - App-server

    @Test("codex runs read-only with on-request approvals, and an empty answer is an empty limits list")
    func appServerArguments() async throws {
        let temp = try TemporaryDirectory()
        let argsFile = temp.url.appending(path: "codex-args")
        let collector = CodexCollector(
            store: RecordStore(directory: temp.url.appending(path: "records")),
            localScanner: scanner(home: Self.local.appending(path: "codex"), cache: temp.url.appending(path: "cache")),
            appServer: appServer(["CODEX_ARGS_FILE": argsFile.path(percentEncoded: false)]),
            now: { Self.now }
        )
        let record = await collector.run()

        #expect(try String(contentsOf: argsFile, encoding: .utf8) == "-s\nread-only\n-a\non-request\napp-server\n")
        #expect(record.id == "codex")
        #expect(record.name == "Codex")
        #expect(record.ready)
        #expect(record.limits.isEmpty)
        #expect(record.usageStatusText == "")
        #expect(record.authHelpText == "Run `codex login` to authenticate.")
        #expect(record.todayTotalTokens == 210)
        #expect(try collector.store.load(id: "codex") == record)
    }

    @Test("Limits and plan come from the app-server's rate limits")
    func rateLimits() {
        let result = appServer([
            "CODEX_ACCOUNT": #"{"type":"chatgpt","planType":"plus"}"#,
            "CODEX_RATE_LIMITS": #"{"planType":"pro","primary":{"usedPercent":7,"windowDurationMins":10080,"resetsAt":1789800000},"secondary":{"usedPercent":25,"windowDurationMins":300}}"#,
        ]).fetchBlocking()
        #expect(result == .init(
            limits: [
                .init(label: "Weekly (7-day)", percent: 0.07, resetsAt: OmarchyDate.isoformat(Date(timeIntervalSince1970: 1_789_800_000))),
                .init(label: "5h window", percent: 0.25),
            ],
            tierLabel: "pro"
        ))
    }

    @Test("Without rate limits the plan falls back to the account")
    func accountPlan() {
        #expect(appServer(["CODEX_ACCOUNT": #"{"type":"chatgpt"}"#]).fetchBlocking().tierLabel == "chatgpt")
    }

    @Test("No codex on the search path says so")
    func missing() {
        let result = appServer(searchPath: []).fetchBlocking()
        #expect(result.usageStatusText == "Codex unavailable")
        #expect(result.authHelpText == "codex not found in PATH")
    }

    @Test("An app-server that never answers times out on the method it was asked")
    func silent() {
        let result = appServer(["CODEX_SILENT": "1"], timeout: 0.3).fetchBlocking()
        #expect(result.usageStatusText == "Codex limits unavailable")
        #expect(result.authHelpText == "initialize")
        #expect(result.limits.isEmpty)
    }

    @Test("Limit windows are labelled by their length", arguments: [
        (10080, "Weekly (7-day)"), (300, "5h window"), (60, "1h window"), (30, "30m window"), (0, "Limit"),
    ])
    func windowLabels(minutes: Int, label: String) {
        #expect(CodexAppServer.limitWindow(["usedPercent": 10, "windowDurationMins": minutes])?.label == label)
    }

    @Test("A window without usedPercent is no limit")
    func noUsedPercent() {
        #expect(CodexAppServer.limitWindow(["windowDurationMins": 300]) == nil)
        #expect(CodexAppServer.limitWindow(["usedPercent": NSNull()]) == nil)
        #expect(CodexAppServer.limitWindow("primary") == nil)
    }

    @Test("opencode model ids keep their last path segment")
    func opencodeModel() {
        #expect(OpencodeModel.lastSegment("accounts/fireworks/models/kimi-k2") == "kimi-k2")
        #expect(OpencodeModel.lastSegment("gpt-5.2-codex/") == "gpt-5.2-codex")
        #expect(CodexLocalScanner.modelName(OpencodeModel.lastSegment("")) == "codex")
    }
}
