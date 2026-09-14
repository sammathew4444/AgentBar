import Foundation
import OSLog

/// Produces the Codex usage record and writes it through the store (`main` in
/// omarchy-agent-usage-codex): local stats plus the app-server's limits and plan.
struct CodexCollector: Sendable {
    static let agentID = "codex"
    static let agentName = "Codex"
    static let authHelp = "Run `codex login` to authenticate."

    let store: RecordStore
    let localScanner: CodexLocalScanner
    let appServer: CodexAppServer
    let now: @Sendable () -> Date

    init(
        store: RecordStore = RecordStore(),
        cacheDirectory: URL = URL.cachesDirectory.appending(path: "AgentBar", directoryHint: .isDirectory),
        localScanner: CodexLocalScanner? = nil,
        appServer: CodexAppServer? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.localScanner = localScanner ?? .live(cacheDirectory: cacheDirectory)
        self.appServer = appServer ?? .live()
        self.now = now
    }

    /// - Parameters:
    ///   - force: rescan past the cache, for a refresh a person asked for.
    ///   - scanMaxAge: how old a reused local scan may be.
    @discardableResult
    func run(force: Bool = false, scanMaxAge: TimeInterval = CodexLocalScanner.scanReuse) async -> UsageRecord {
        async let stats = localScanner.stats(now: now(), maxAge: force ? 0 : scanMaxAge)
        async let server = appServer.fetch()
        let (local, rpc) = await (stats, server)

        var record = UsageRecord(
            id: Self.agentID,
            name: Self.agentName,
            updatedAt: OmarchyDate.isoformat(now()),
            ready: true,
            hasLocalStats: true,
            tierLabel: rpc.tierLabel,
            usageStatusText: rpc.usageStatusText,
            authHelpText: rpc.authHelpText,
            limits: rpc.limits
        )
        record.apply(local)
        do {
            try store.write(record)
        } catch {
            Logger.collector.error("Couldn't write the Codex record: \(String(describing: error), privacy: .public)")
        }
        return record
    }
}
