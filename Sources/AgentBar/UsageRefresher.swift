import Foundation
import OSLog

/// A collector besides Claude's, refreshed alongside it.
protocol UsageCollector: Sendable {
    var agentID: String { get }
    /// `limitsOnly` is a panel opening: fresh limits, but a recent local scan may be reused.
    func refresh(force: Bool, limitsOnly: Bool) async
}

extension CodexCollector: UsageCollector {
    var agentID: String { Self.agentID }

    func refresh(force: Bool, limitsOnly: Bool) async {
        await run(force: force, scanMaxAge: limitsOnly ? CodexLocalScanner.limitsOnlyReuse : CodexLocalScanner.scanReuse)
    }
}

extension GrokCollector: UsageCollector {
    var agentID: String { Self.agentID }

    func refresh(force: Bool, limitsOnly: Bool) async {
        await run(force: force, scanMaxAge: limitsOnly ? GrokLocalScanner.limitsOnlyReuse : GrokLocalScanner.scanReuse)
    }
}

/// When collection runs. Mirrors Main.qml: a full refresh on start and every
/// `refreshIntervalSec`, a limits refresh when the panel opens, one sooner retry 30 s after a
/// collector advises it, overlapping requests collapsed into one follow-up run, and disabled
/// agents skipped.
@MainActor
final class UsageRefresher {
    enum Kind: Int, Comparable {
        case scheduled, panelOpened, forced

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    /// Main.qml's `limitsRetry`.
    static let retryDelay: Duration = .seconds(30)

    var onRecordsChanged: (() -> Void)?
    /// Omarchy's `providerEnabled`: a disabled agent isn't collected.
    var isEnabled: (String) -> Bool = { _ in true }

    private let collector: ClaudeCollector
    private let others: [any UsageCollector]
    private var interval: Duration
    private var gate = RefreshGate()
    private var running = false
    private var pending: Kind?
    private var timerTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    /// After a denial, only a person opening the panel or forcing a refresh asks again.
    private var keychainDenied = false

    init(collector: ClaudeCollector, others: [any UsageCollector] = [], intervalSeconds: Int = AppSettings.defaultRefreshInterval) {
        self.collector = collector
        self.others = others
        interval = .seconds(intervalSeconds)
    }

    /// Runs now, then every interval (`triggeredOnStart`).
    func start() {
        guard timerTask == nil else { return }
        scheduleTimer(runNow: true)
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
        retryTask?.cancel()
        retryTask = nil
    }

    /// A new interval starts counting from now, as a Timer's does when its interval changes.
    func setInterval(seconds: Int) {
        interval = .seconds(seconds)
        guard timerTask != nil else { return }
        timerTask?.cancel()
        scheduleTimer(runNow: false)
    }

    private func scheduleTimer(runNow: Bool) {
        timerTask = Task { [weak self] in
            var first = runNow
            while !Task.isCancelled {
                if first {
                    self?.request(.scheduled)
                }
                first = true
                guard let interval = self?.interval else { return }
                try? await Task.sleep(for: interval)
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
        let enabledOthers = others.filter { isEnabled($0.agentID) }
        async let othersDone: Void = Self.refresh(enabledOthers, force: force, limitsOnly: limitsOnly)
        var outcome: ClaudeCollector.Outcome?
        if isEnabled(ClaudeCollector.agentID) {
            outcome = await collector.run(
                force: force,
                keychainAllowed: !(keychainDenied && kind == .scheduled),
                scanMaxAge: limitsOnly ? ClaudeLocalScanner.limitsOnlyReuse : ClaudeLocalScanner.scanReuse
            )
        }
        await othersDone

        retryTask?.cancel()
        retryTask = nil
        if let outcome {
            keychainDenied = outcome.keychainDenied
            if let retryAfter = outcome.retryAfter {
                gate.rateLimited(until: Date().addingTimeInterval(retryAfter))
            }
            if outcome.record.retryAdvised {
                retryTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.retryDelay)
                    guard !Task.isCancelled else { return }
                    self?.request(.scheduled)
                }
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
