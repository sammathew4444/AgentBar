import Foundation
import OSLog

/// A collector besides Claude's, refreshed alongside it.
protocol UsageCollector: Sendable {
    /// `limitsOnly` is a panel opening: fresh limits, but a recent local scan may be reused.
    func refresh(force: Bool, limitsOnly: Bool) async
}

extension CodexCollector: UsageCollector {
    func refresh(force: Bool, limitsOnly: Bool) async {
        await run(force: force, scanMaxAge: limitsOnly ? CodexLocalScanner.limitsOnlyReuse : CodexLocalScanner.scanReuse)
    }
}

extension GrokCollector: UsageCollector {
    func refresh(force: Bool, limitsOnly: Bool) async {
        await run(force: force, scanMaxAge: limitsOnly ? GrokLocalScanner.limitsOnlyReuse : GrokLocalScanner.scanReuse)
    }
}

/// When collection runs. Mirrors Main.qml: a full refresh on start and every
/// `refreshIntervalSec` (900 s), a limits refresh when the panel opens, one sooner retry 30 s
/// after a collector advises it, and overlapping requests collapsed into one follow-up run.
@MainActor
final class UsageRefresher {
    enum Kind: Int, Comparable {
        case scheduled, panelOpened, forced

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    /// `refreshIntervalSec` default in manifest.json.
    static let refreshInterval: Duration = .seconds(900)
    /// Main.qml's `limitsRetry`.
    static let retryDelay: Duration = .seconds(30)

    var onRecordsChanged: (() -> Void)?

    private let collector: ClaudeCollector
    private let others: [any UsageCollector]
    private var gate = RefreshGate()
    private var running = false
    private var pending: Kind?
    private var timerTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    /// After a denial, only a person opening the panel or forcing a refresh asks again.
    private var keychainDenied = false

    init(collector: ClaudeCollector, others: [any UsageCollector] = []) {
        self.collector = collector
        self.others = others
    }

    func start() {
        guard timerTask == nil else { return }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.request(.scheduled)
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    func request(_ kind: Kind) {
        if kind == .panelOpened, !gate.allowsPanelRefresh(at: Date()) {
            Logger.collector.debug("Skipping panel refresh inside the floor")
            return
        }
        if running {
            pending = max(pending ?? kind, kind)
            return
        }
        running = true
        gate.started(at: Date())
        Task { await run(kind) }
    }

    private func run(_ kind: Kind) async {
        // Opening the panel wants fresh limits, not another walk over every session file.
        let limitsOnly = kind == .panelOpened
        let force = kind == .forced
        async let othersDone: Void = Self.refresh(others, force: force, limitsOnly: limitsOnly)
        let outcome = await collector.run(
            force: force,
            keychainAllowed: !(keychainDenied && kind == .scheduled),
            scanMaxAge: limitsOnly ? ClaudeLocalScanner.limitsOnlyReuse : ClaudeLocalScanner.scanReuse
        )
        await othersDone
        keychainDenied = outcome.keychainDenied
        if let retryAfter = outcome.retryAfter {
            gate.rateLimited(until: Date().addingTimeInterval(retryAfter))
        }

        retryTask?.cancel()
        retryTask = nil
        if outcome.record.retryAdvised {
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: Self.retryDelay)
                guard !Task.isCancelled else { return }
                self?.request(.scheduled)
            }
        }

        running = false
        onRecordsChanged?()
        if let next = pending {
            pending = nil
            request(next)
        }
    }

    private nonisolated static func refresh(_ collectors: [any UsageCollector], force: Bool, limitsOnly: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            for collector in collectors {
                group.addTask { await collector.refresh(force: force, limitsOnly: limitsOnly) }
            }
        }
    }
}

/// Keeps panel-driven refreshes from hammering the endpoint: at most one per `panelFloor`,
/// and none before a 429's Retry-After has passed. Scheduled and forced refreshes aren't gated.
struct RefreshGate: Equatable {
    static let panelFloor: TimeInterval = ClaudeCollector.probeReuseInterval

    private(set) var lastStart: Date?
    private(set) var notBefore: Date?

    func allowsPanelRefresh(at now: Date) -> Bool {
        if let notBefore, now < notBefore { return false }
        if let lastStart, now.timeIntervalSince(lastStart) < Self.panelFloor { return false }
        return true
    }

    mutating func started(at date: Date) {
        lastStart = date
    }

    mutating func rateLimited(until date: Date) {
        notBefore = max(notBefore ?? date, date)
    }
}
