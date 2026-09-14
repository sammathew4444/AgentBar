import Foundation
import Testing
@testable import AgentBar

// MARK: - Fakes. Nothing here touches the network or the real Keychain.

actor FakeKeychain: KeychainReading {
    private let result: KeychainResult
    private(set) var reads = 0

    init(_ result: KeychainResult) {
        self.result = result
    }

    func readClaudeCredentials() async -> KeychainResult {
        reads += 1
        return result
    }
}

actor FakeTransport: HTTPTransport {
    enum Reply: Sendable {
        case http(Int, headers: [String: String] = [:], body: String)
        case offline
    }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: Reply...) {
        self.replies = replies
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else {
            Issue.record("Unexpected request to \(request.url?.absoluteString ?? "?")")
            throw URLError(.notConnectedToInternet)
        }
        switch replies.removeFirst() {
        case .offline:
            throw URLError(.notConnectedToInternet)
        case let .http(status, headers, body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (Data(body.utf8), response)
        }
    }
}

final class TestClock: @unchecked Sendable {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

// MARK: - Tests

@Suite("Claude collector")
struct ClaudeCollectorTests {
    /// 2026-09-14T15:00:00Z
    private static let start = Date(timeIntervalSince1970: 1_789_398_000)
    private static let token = "fake-access-token-never-persisted"
    private static let payload = """
    {"five_hour":{"utilization":37.0,"resets_at":"2026-09-14T18:00:00Z"},
     "seven_day":{"utilization":12.0,"resets_at":"2026-09-19T09:00:00.123456+00:00"}}
    """
    private static let expectedLimits: [UsageRecord.Limit] = [
        .init(label: "Session (5-hour)", percent: 0.37, resetsAt: "2026-09-14T18:00:00+00:00"),
        .init(label: "Weekly (7-day)", percent: 0.12, resetsAt: "2026-09-19T09:00:00.123456+00:00"),
    ]

    private static func login(expiresIn seconds: TimeInterval = 3600) -> KeychainResult {
        let expiresAt = Int((start.timeIntervalSince1970 + seconds) * 1000)
        return .found(Data("""
        {"claudeAiOauth":{"accessToken":"\(token)","refreshToken":"refresh","expiresAt":\(expiresAt),
         "rateLimitTier":"default_claude_max_20x","subscriptionType":"max"}}
        """.utf8))
    }

    private func collector(_ directory: URL, keychain: FakeKeychain, transport: FakeTransport, clock: TestClock) -> ClaudeCollector {
        ClaudeCollector(
            keychain: keychain,
            transport: transport,
            store: RecordStore(directory: directory.appending(path: "records")),
            cacheDirectory: directory.appending(path: "cache"),
            now: { clock.now }
        )
    }

    @Test("A successful probe fills the record, caches the limits, and writes it through the store")
    func success() async throws {
        let temp = try TemporaryDirectory()
        let transport = FakeTransport(.http(200, body: Self.payload))
        let collector = collector(temp.url, keychain: FakeKeychain(Self.login()), transport: transport, clock: TestClock(Self.start))

        let outcome = await collector.run()

        let record = outcome.record
        #expect(record.id == "claude")
        #expect(record.name == "Claude Code")
        #expect(record.schemaVersion == 1)
        #expect(record.updatedAt == "2026-09-14T15:00:00+00:00")
        #expect(record.ready)
        #expect(record.tierLabel == "Max 20x")
        #expect(record.usageStatusText == "")
        #expect(record.authHelpText == "Run `claude auth login` to restore authoritative usage.")
        #expect(record.limits == Self.expectedLimits)
        #expect(!record.retryAdvised)
        #expect(try collector.store.load(id: "claude") == record)
        #expect(collector.readProbeCache()?.limits == Self.expectedLimits)

        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
    }

    @Test("Neither the record nor the cache on disk contains the token")
    func tokenNeverPersisted() async throws {
        let temp = try TemporaryDirectory()
        let collector = collector(temp.url, keychain: FakeKeychain(Self.login()), transport: FakeTransport(.http(200, body: Self.payload)), clock: TestClock(Self.start))
        await collector.run()

        let root = temp.url.path(percentEncoded: false)
        var files = 0
        for path in try FileManager.default.subpathsOfDirectory(atPath: root) {
            var isDirectory: ObjCBool = false
            let full = (root as NSString).appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            files += 1
            let contents = try String(contentsOfFile: full, encoding: .utf8)
            #expect(!contents.contains(Self.token), "\(path)")
            #expect(!contents.contains("refresh"), "\(path)")
        }
        #expect(files == 2)
    }

    @Test("Not signed in: waiting for auth, and no request")
    func notFound() async throws {
        let temp = try TemporaryDirectory()
        let transport = FakeTransport()
        let outcome = await collector(temp.url, keychain: FakeKeychain(.notFound), transport: transport, clock: TestClock(Self.start)).run()
        #expect(outcome.record.usageStatusText == "Waiting for auth")
        #expect(outcome.record.authHelpText == "Run `claude auth login` to restore authoritative usage.")
        #expect(outcome.record.limits.isEmpty)
        #expect(!outcome.record.ready)
        #expect(!outcome.keychainDenied)
        #expect(await transport.requests.isEmpty)
    }

    @Test("A Keychain item that isn't a Claude login reads as not signed in")
    func malformedItem() async throws {
        let temp = try TemporaryDirectory()
        let outcome = await collector(temp.url, keychain: FakeKeychain(.found(Data("garbage".utf8))), transport: FakeTransport(), clock: TestClock(Self.start)).run()
        #expect(outcome.record.usageStatusText == "Waiting for auth")
    }

    @Test("Keychain denied is its own state, distinct from not signed in")
    func denied() async throws {
        let temp = try TemporaryDirectory()
        let transport = FakeTransport()
        let outcome = await collector(temp.url, keychain: FakeKeychain(.denied), transport: transport, clock: TestClock(Self.start)).run()
        #expect(outcome.keychainDenied)
        #expect(outcome.record.usageStatusText == "Keychain access denied")
        #expect(outcome.record.authHelpText.contains("Claude Code-credentials"))
        #expect(await transport.requests.isEmpty)
    }

    @Test("keychainAllowed: false doesn't ask the Keychain again")
    func keychainNotAsked() async throws {
        let temp = try TemporaryDirectory()
        let keychain = FakeKeychain(Self.login())
        let outcome = await collector(temp.url, keychain: keychain, transport: FakeTransport(), clock: TestClock(Self.start)).run(keychainAllowed: false)
        #expect(outcome.keychainDenied)
        #expect(await keychain.reads == 0)
    }

    @Test("An expired token isn't sent, and says so")
    func expired() async throws {
        let temp = try TemporaryDirectory()
        let transport = FakeTransport()
        let outcome = await collector(temp.url, keychain: FakeKeychain(Self.login(expiresIn: -60)), transport: transport, clock: TestClock(Self.start)).run()
        #expect(outcome.record.usageStatusText == "Sign-in expired")
        #expect(outcome.record.authHelpText == "Claude Code's saved sign-in expired. Start Claude Code, or run `claude auth login`, to refresh it.")
        #expect(await transport.requests.isEmpty)
    }

    @Test("An expired token keeps the last limits whose windows are still open")
    func expiredWithFallback() async throws {
        let temp = try TemporaryDirectory()
        let clock = TestClock(Self.start)
        await collector(temp.url, keychain: FakeKeychain(Self.login()), transport: FakeTransport(.http(200, body: Self.payload)), clock: clock).run()

        clock.advance(7200)
        let outcome = await collector(temp.url, keychain: FakeKeychain(Self.login(expiresIn: 3600)), transport: FakeTransport(), clock: clock).run()
        #expect(outcome.record.usageStatusText == "Sign-in expired")
        #expect(outcome.record.authHelpText == "Claude Code's saved sign-in expired — showing the last known limits. Start Claude Code, or run `claude auth login`, to refresh it.")
        #expect(outcome.record.limits == Self.expectedLimits)
    }

    @Test("A probe inside the 15 s reuse window isn't repeated, unless forced")
    func reuseWindow() async throws {
        let temp = try TemporaryDirectory()
        let clock = TestClock(Self.start)
        let transport = FakeTransport(.http(200, body: Self.payload), .http(200, body: Self.payload), .http(200, body: Self.payload))
        let collector = collector(temp.url, keychain: FakeKeychain(Self.login()), transport: transport, clock: clock)

        await collector.run()
        clock.advance(10)
        #expect(await collector.run().record.limits == Self.expectedLimits)
        #expect(await transport.requests.count == 1)

        await collector.run(force: true)
        #expect(await transport.requests.count == 2)

        clock.advance(16)
        await collector.run()
        #expect(await transport.requests.count == 3)
    }

    @Test("Offline with cached limits: the last values stay and a sooner retry is advised")
    func offlineWithFallback() async throws {
        let temp = try TemporaryDirectory()
        let clock = TestClock(Self.start)
        let collector = collector(temp.url, keychain: FakeKeychain(Self.login()), transport: FakeTransport(.http(200, body: Self.payload), .offline), clock: clock)
        await collector.run()

        clock.advance(60)
        let outcome = await collector.run()
        #expect(outcome.record.limits == Self.expectedLimits)
        #expect(outcome.record.usageStatusText == "")
        #expect(outcome.record.retryAdvised)
        #expect(try collector.store.load(id: "claude").retryAdvised)
    }

    @Test("Offline with nothing cached says the endpoint couldn't be reached")
    func offlineWithoutFallback() async throws {
        let temp = try TemporaryDirectory()
        let outcome = await collector(temp.url, keychain: FakeKeychain(Self.login()), transport: FakeTransport(.offline), clock: TestClock(Self.start)).run()
        #expect(outcome.record.usageStatusText == "Claude limits unavailable")
        #expect(outcome.record.authHelpText == "Couldn't reach Anthropic's usage endpoint. Retrying shortly. Local Claude Code stats are still shown.")
        #expect(outcome.record.retryAdvised)
    }

    @Test("A cached limit whose window has reset is dropped")
    func resetWindowDropped() async throws {
        let temp = try TemporaryDirectory()
        let clock = TestClock(Self.start)
        let collector = collector(temp.url, keychain: FakeKeychain(Self.login(expiresIn: 86_400)), transport: FakeTransport(.http(200, body: Self.payload), .offline), clock: clock)
        await collector.run()

        clock.advance(4 * 3600) // past the session reset at 18:00, before the weekly one
        let outcome = await collector.run()
        #expect(outcome.record.limits == [Self.expectedLimits[1]])
    }

    @Test("Rate limited: the help text names the wait, and the wait is surfaced")
    func rateLimited() async throws {
        let temp = try TemporaryDirectory()
        let outcome = await collector(temp.url, keychain: FakeKeychain(Self.login()), transport: FakeTransport(.http(429, headers: ["Retry-After": "30"], body: "")), clock: TestClock(Self.start)).run()
        #expect(outcome.retryAfter == 30)
        #expect(outcome.record.usageStatusText == "Claude limits unavailable")
        #expect(outcome.record.authHelpText == "Anthropic's usage endpoint is rate limiting checks right now (retry after 30s). Local Claude Code stats are still shown.")
        #expect(!outcome.record.retryAdvised)
    }

    @Test("Unauthorized reports the status")
    func unauthorized() async throws {
        let temp = try TemporaryDirectory()
        let outcome = await collector(temp.url, keychain: FakeKeychain(Self.login()), transport: FakeTransport(.http(401, body: #"{"error":"invalid"}"#)), clock: TestClock(Self.start)).run()
        #expect(outcome.record.usageStatusText == "Claude limits unavailable")
        #expect(outcome.record.authHelpText == "Anthropic's usage endpoint returned status 401. Local Claude Code stats are still shown.")
    }
}
