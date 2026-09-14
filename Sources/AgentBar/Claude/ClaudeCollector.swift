import Foundation
import OSLog

/// Produces the Claude Code usage record and writes it through the store. The limits half of
/// omarchy-agent-usage-claude (`collect_limits` and `main`); local transcript stats come in Phase 5.
struct ClaudeCollector: Sendable {
    static let agentID = "claude"
    static let agentName = "Claude Code"
    static let authHelp = "Run `claude auth login` to restore authoritative usage."
    /// `PROBE_MIN_INTERVAL_SECONDS`: a successful probe is reused this long unless forced.
    static let probeReuseInterval: TimeInterval = 15

    struct Outcome: Sendable, Equatable {
        var record: UsageRecord
        var keychainDenied: Bool
        /// From a 429's Retry-After, in seconds.
        var retryAfter: TimeInterval?
    }

    let keychain: any KeychainReading
    let transport: any HTTPTransport
    let store: RecordStore
    /// Holds `claude-limits.json`, the last successful probe. Never holds a token.
    let cacheDirectory: URL
    let localScanner: ClaudeLocalScanner
    let now: @Sendable () -> Date

    init(
        keychain: any KeychainReading = SecurityCLIKeychain(),
        transport: any HTTPTransport = URLSessionTransport(),
        store: RecordStore = RecordStore(),
        cacheDirectory: URL = URL.cachesDirectory.appending(path: "AgentBar", directoryHint: .isDirectory),
        localScanner: ClaudeLocalScanner? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.keychain = keychain
        self.transport = transport
        self.store = store
        self.cacheDirectory = cacheDirectory
        self.localScanner = localScanner ?? .live(cacheDirectory: cacheDirectory)
        self.now = now
    }

    /// - Parameters:
    ///   - force: skip the probe-reuse window and rescan, for a refresh a person asked for.
    ///   - keychainAllowed: false to act as if access were denied without asking again.
    ///   - scanMaxAge: how old a reused local scan may be; `force` makes it 0.
    @discardableResult
    func run(force: Bool = false, keychainAllowed: Bool = true, scanMaxAge: TimeInterval = ClaudeLocalScanner.scanReuse) async -> Outcome {
        let outcome = await collect(force: force, keychainAllowed: keychainAllowed, scanMaxAge: scanMaxAge)
        do {
            try store.write(outcome.record)
        } catch {
            Logger.collector.error("Couldn't write the Claude record: \(String(describing: error), privacy: .public)")
        }
        return outcome
    }

    func collect(force: Bool, keychainAllowed: Bool, scanMaxAge: TimeInterval = ClaudeLocalScanner.scanReuse) async -> Outcome {
        let start = now()
        let stats = await localScanner.stats(now: start, maxAge: force ? 0 : scanMaxAge)
        var limits: [UsageRecord.Limit] = []
        var status = ""
        var help = Self.authHelp
        var retryAdvised = false
        var retryAfter: TimeInterval?
        var plan = ""
        var denied = false

        let cached = readProbeCache()
        // A cached figure only describes its window until that window resets.
        let fallback = cached?.limits.filter { Self.windowOpen($0, at: start) } ?? []

        let keychainResult: KeychainResult = keychainAllowed ? await keychain.readClaudeCredentials() : .denied
        let login: ClaudeLogin?
        switch keychainResult {
        case .found(let data): login = ClaudeLogin.parse(data)
        case .notFound: login = nil
        case .denied: login = nil; denied = true
        case .failed(let code):
            Logger.collector.error("security exited with status \(code, privacy: .public)")
            login = nil
        }
        plan = login?.plan ?? ""

        if denied {
            // macOS only: Omarchy reads a file and has no equivalent state.
            limits = fallback
            status = "Keychain access denied"
            help = "Allow access to “\(SecurityCLIKeychain.service)” when macOS asks, or in Keychain Access, to restore authoritative usage."
        } else if let login, !login.accessToken.isEmpty {
            if login.isExpired(at: start) {
                limits = fallback
                status = "Sign-in expired"
                help = "Claude Code's saved sign-in expired"
                    + (fallback.isEmpty ? "." : " — showing the last known limits.")
                    + " Start Claude Code, or run `claude auth login`, to refresh it."
            } else if !fallback.isEmpty, !force, let cached, start.timeIntervalSince1970 * 1000 - cached.fetchedAtMs < Self.probeReuseInterval * 1000 {
                limits = fallback
            } else {
                switch await ClaudeUsageAPI.probe(accessToken: login.accessToken, transport: transport) {
                case .limits(let fresh):
                    limits = fresh
                    writeProbeCache(ProbeCache(fetchedAtMs: (now().timeIntervalSince1970 * 1000).rounded(), limits: fresh))
                case .failed(let helpText, let transportFailure, let after):
                    // The first probe after login often fires before the network is up.
                    retryAdvised = transportFailure
                    retryAfter = after
                    if fallback.isEmpty {
                        status = "Claude limits unavailable"
                        help = helpText
                    } else {
                        limits = fallback
                    }
                    Logger.collector.notice("Claude limits probe failed: \(helpText, privacy: .public)")
                }
            }
        } else {
            limits = fallback
            status = "Waiting for auth"
        }

        var record = UsageRecord(
            id: Self.agentID,
            name: Self.agentName,
            updatedAt: OmarchyDate.isoformat(now()),
            ready: stats.totalPrompts > 0 || !limits.isEmpty,
            hasLocalStats: true,
            tierLabel: plan,
            usageStatusText: status,
            authHelpText: help,
            retryAdvised: retryAdvised,
            limits: limits
        )
        record.apply(stats)
        return Outcome(record: record, keychainDenied: denied, retryAfter: retryAfter)
    }

    // MARK: - Probe cache

    struct ProbeCache: Codable, Equatable {
        var fetchedAtMs: Double
        var limits: [UsageRecord.Limit]
    }

    var probeCacheURL: URL { cacheDirectory.appending(path: "claude-limits.json") }

    func readProbeCache() -> ProbeCache? {
        guard let data = try? Data(contentsOf: probeCacheURL) else { return nil }
        return try? JSONDecoder().decode(ProbeCache.self, from: data)
    }

    private func writeProbeCache(_ cache: ProbeCache) {
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(cache).write(to: probeCacheURL, options: .atomic)
        } catch {
            Logger.collector.error("Couldn't write the limits cache: \(String(describing: error), privacy: .public)")
        }
    }

    /// `limit_window_open`: a window with no reset time, or one that won't parse, stays open.
    static func windowOpen(_ limit: UsageRecord.Limit, at now: Date) -> Bool {
        guard let resetsAt = OmarchyDate.parse(limit.resetsAt) else { return true }
        return resetsAt > now
    }
}
