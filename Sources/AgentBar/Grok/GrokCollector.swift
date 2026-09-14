import Foundation
import OSLog

/// Produces the Grok usage record in Omarchy's record contract, so the panel shows it like any
/// other agent: the plan from Grok's subscription tier, one limit from its credit allowance, and
/// local stats from its sessions. Omarchy has no Grok collector; this one is AgentBar's.
struct GrokCollector: Sendable {
    static let agentID = "grok"
    static let agentName = "Grok"

    let store: RecordStore
    let localScanner: GrokLocalScanner
    let now: @Sendable () -> Date

    init(
        store: RecordStore = RecordStore(),
        cacheDirectory: URL = URL.cachesDirectory.appending(path: "AgentBar", directoryHint: .isDirectory),
        localScanner: GrokLocalScanner? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.localScanner = localScanner ?? .live(cacheDirectory: cacheDirectory)
        self.now = now
    }

    @discardableResult
    func run(force: Bool = false, scanMaxAge: TimeInterval = GrokLocalScanner.scanReuse) async -> UsageRecord {
        let start = now()
        let stats = await localScanner.stats(now: start, maxAge: force ? 0 : scanMaxAge)
        let billing = localScanner.latestBilling(now: start)
        let limits = billing?.limit.map { [$0] } ?? []

        var record = UsageRecord(
            id: Self.agentID,
            name: Self.agentName,
            updatedAt: OmarchyDate.isoformat(now()),
            ready: stats.totalPrompts > 0 || !limits.isEmpty,
            hasLocalStats: true,
            tierLabel: billing?.tier ?? "",
            limits: limits
        )
        record.apply(stats)
        do {
            try store.write(record)
        } catch {
            Logger.collector.error("Couldn't write the Grok record: \(String(describing: error), privacy: .public)")
        }
        return record
    }
}
