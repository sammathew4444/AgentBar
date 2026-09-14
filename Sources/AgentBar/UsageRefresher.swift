import Foundation
import OSLog

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
    private let codex: CodexCollector?
    private var gate = RefreshGate()
    private var running = false
    private var pending: Kind?
    private var timerTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    /// After a denial, only a person opening the panel or forcing a refresh asks again.
    private var keychainDenied = false

    init(collector: ClaudeCollector, codex: CodexCollector? = nil) {
        self.collector = collector
        self.codex = codex
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
        async let codexRecord = codex?.run(
            force: kind == .forced,
            scanMaxAge: limitsOnly ? CodexLocalScanner.limitsOnlyReuse : CodexLocalScanner.scanReuse
        )
        let outcome = await collector.run(
            force: kind == .forced,
            keychainAllowed: !(keychainDenied && kind == .scheduled),
            scanMaxAge: limitsOnly ? ClaudeLocalScanner.limitsOnlyReuse : ClaudeLocalScanner.scanReuse
        )
        _ = await codexRecord
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
