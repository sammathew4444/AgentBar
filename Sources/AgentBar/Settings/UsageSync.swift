import Foundation

/// Omarchy's synced aggregation (shell/plugins/agents/Main.qml): each machine writes a snapshot of
/// its local stats into a shared folder, and every snapshot there is merged, so today, the week
/// and all-time cover every machine. Rate limits and balances are per account and never travel.
/// Snapshots use Omarchy's format, so Macs and Omarchy machines can share one folder.
enum UsageSync {
    /// `providerSnapshot` fields, plus the aggregate's `deviceCount` and `devices`.
    struct ProviderStats: Codable, Equatable, Sendable {
        var providerId: String
        var providerName: String
        var ready: Bool
        var hasLocalStats: Bool
        var hasPromptStats: Bool
        var scope: String?
        var todayPrompts: Int
        var todaySessions: Int
        var todayTotalTokens: Int
        var todayTokensByModel: [String: Int]
        var recentDays: [UsageRecord.RecentDay]
        var totalPrompts: Int
        var totalSessions: Int
        var activeDays: Int
        var activeDates: [String]?
        var modelUsage: [String: UsageRecord.TokenBucket]
        var deviceCount: Int?
        var devices: [String]?
    }

    struct Snapshot: Codable, Equatable, Sendable {
        var schemaVersion: Int
        var deviceId: String
        var updatedAt: String
        var providers: [String: ProviderStats]
    }

    struct Aggregate: Equatable, Sendable {
        var deviceCount: Int
        var devices: [String]
        var providers: [String: ProviderStats]
    }

    static let mkdirFailed = "Usage sync mkdir failed"
    static let scanFailed = "Usage sync scan failed"

    /// This Mac's name, standing in for Omarchy's `$HOSTNAME`.
    static var hostname: String {
        var name = ProcessInfo.processInfo.hostName
        if name.hasSuffix(".local") { name.removeLast(".local".count) }
        return name
    }

    // MARK: - Names

    /// `safeDeviceId`: letters, digits, `_`, `.` and `-`, trimmed, at most 80 characters.
    static func safeDeviceId(_ raw: String, hostname: String = UsageSync.hostname) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { value = hostname.isEmpty ? "device" : hostname }
        value = value.replacing(/[^A-Za-z0-9_.-]+/, with: "-").replacing(/^[._-]+|[._-]+$/, with: "")
        if value.isEmpty { value = "device" }
        return String(value.prefix(80))
    }

    /// `safeSnapshotFileName`: a bare `.json` name, defaulting to the device id.
    static func safeSnapshotFileName(_ raw: String, deviceId: String, hostname: String = UsageSync.hostname) -> String {
        let fallback = safeDeviceId(deviceId, hostname: hostname) + ".json"
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { value = fallback }
        value = String(value.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
        value = value.replacing(/[^A-Za-z0-9_.-]+/, with: "-").replacing(/^[._-]+|[._-]+$/, with: "")
        if value.isEmpty { value = fallback }
        if !value.lowercased().hasSuffix(".json") { value += ".json" }
        return value.count > 100 ? String(value.prefix(95)) + ".json" : value
    }

    /// `syncEffectiveDeviceId`: the device id, or the file name without `.json`.
    static func effectiveDeviceId(_ raw: String, fileName: String, hostname: String = UsageSync.hostname) -> String {
        safeDeviceId(raw.isEmpty ? fileName.replacing(/(?i)\.json$/, with: "") : raw, hostname: hostname)
    }

    // MARK: - Writing

    /// `localSnapshot`: this machine's enabled agents, in the field names older Omarchy versions
    /// wrote, so a fleet on mixed versions merges cleanly both ways.
    static func localSnapshot(records: [UsageRecord], deviceId: String, now: Date) -> Snapshot {
        var providers: [String: ProviderStats] = [:]
        for record in records {
            providers[record.id] = ProviderStats(
                providerId: record.id, providerName: record.name, ready: record.ready,
                hasLocalStats: record.hasLocalStats, hasPromptStats: record.hasPromptStats, scope: record.scope,
                todayPrompts: record.todayPrompts, todaySessions: record.todaySessions, todayTotalTokens: record.todayTotalTokens,
                todayTokensByModel: record.todayTokensByModel, recentDays: record.recentDays,
                totalPrompts: record.totalPrompts, totalSessions: record.totalSessions,
                activeDays: record.activeDays, activeDates: record.activeDates, modelUsage: record.modelUsage
            )
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Snapshot(schemaVersion: 1, deviceId: deviceId, updatedAt: formatter.string(from: now), providers: providers)
    }

    /// `runSync`: make the folder, write this machine's snapshot, then merge everything there.
    static func writeAndScan(_ snapshot: Snapshot, folder: URL, fileName: String, now: Date, calendar: Calendar) -> (Aggregate?, String) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return (nil, mkdirFailed)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if var data = try? encoder.encode(snapshot) {
            data.append(0x0A)
            try? data.write(to: folder.appending(path: fileName), options: .atomic)
        }
        guard let snapshots = readSnapshots(in: folder) else { return (nil, scanFailed) }
        return (aggregate(snapshots, now: now, calendar: calendar), "")
    }

    /// Every `*.json` in the folder that parses and carries `providers`; anything else is skipped.
    static func readSnapshots(in folder: URL) -> [[String: Any]]? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return nil }
        return files
            .filter { $0.pathExtension == "json" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { file -> [String: Any]? in
                guard let data = try? Data(contentsOf: file),
                      let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      snapshot["providers"] is [String: Any] else { return nil }
                return snapshot
            }
    }

    // MARK: - Merging

    /// `aggregateSnapshots`. Device-scoped stats add up; account-scoped ones are the same truth
    /// replicated on every device, so the widest value wins. Active days are unioned by date,
    /// and the week covers this machine's last seven local days.
    static func aggregate(_ snapshots: [[String: Any]], now: Date, calendar: Calendar) -> Aggregate {
        let dates = (0...6).reversed().map { LocalDay.string(calendar.date(byAdding: .day, value: -$0, to: now)!, calendar: calendar) }
        var devices: Set<String> = []

        struct Accumulator {
            var name = ""
            var ready = false, hasLocalStats = false, hasPromptStats = false
            var todayPrompts = 0, todaySessions = 0, todayTotalTokens = 0
            var totalPrompts = 0, totalSessions = 0, activeDays = 0
            var todayTokensByModel: [String: Int] = [:]
            var recentByDay: [String: Int]
            var activeDates: Set<String> = []
            var modelUsage: [String: UsageRecord.TokenBucket] = [:]
            var devices: Set<String> = []
        }
        var providers: [String: Accumulator] = [:]

        for snapshot in snapshots {
            let device = safeDeviceId(truthyString(snapshot["deviceId"]) ?? "device")
            devices.insert(device)
            for (providerID, value) in snapshot["providers"] as? [String: Any] ?? [:] {
                let stats = value as? [String: Any] ?? [:]
                var acc = providers[providerID] ?? Accumulator(recentByDay: Dictionary(uniqueKeysWithValues: dates.map { ($0, 0) }))
                acc.devices.insert(device)
                if acc.name.isEmpty, let name = truthyString(stats["providerName"]) { acc.name = name }
                acc.ready = acc.ready || stats["ready"] as? Bool == true
                // Snapshots from before these fields existed only came from agents that had them.
                acc.hasLocalStats = acc.hasLocalStats || stats["hasLocalStats"] as? Bool != false
                acc.hasPromptStats = acc.hasPromptStats || stats["hasPromptStats"] as? Bool != false
                let additive = (truthyString(stats["scope"]) ?? "device") != "account"
                func combine(_ current: Int, _ value: Any?) -> Int {
                    additive ? current + number(value) : max(current, number(value))
                }
                acc.todayPrompts = combine(acc.todayPrompts, stats["todayPrompts"])
                acc.todaySessions = combine(acc.todaySessions, stats["todaySessions"])
                acc.todayTotalTokens = combine(acc.todayTotalTokens, stats["todayTotalTokens"])
                acc.totalPrompts = combine(acc.totalPrompts, stats["totalPrompts"])
                acc.totalSessions = combine(acc.totalSessions, stats["totalSessions"])
                for date in stats["activeDates"] as? [Any] ?? [] { acc.activeDates.insert("\(date)") }
                acc.activeDays = max(acc.activeDays, number(stats["activeDays"]))
                for (model, count) in stats["todayTokensByModel"] as? [String: Any] ?? [:] {
                    acc.todayTokensByModel[model] = combine(acc.todayTokensByModel[model] ?? 0, count)
                }
                for case let day as [String: Any] in stats["recentDays"] as? [Any] ?? [] {
                    let date = truthyString(day["date"]) ?? ""
                    if let current = acc.recentByDay[date] { acc.recentByDay[date] = combine(current, day["messageCount"]) }
                }
                for (model, value) in stats["modelUsage"] as? [String: Any] ?? [:] {
                    let source = value as? [String: Any] ?? [:]
                    var bucket = acc.modelUsage[model] ?? .init()
                    bucket.inputTokens = combine(bucket.inputTokens, source["inputTokens"])
                    bucket.outputTokens = combine(bucket.outputTokens, source["outputTokens"])
                    bucket.cacheReadInputTokens = combine(bucket.cacheReadInputTokens, source["cacheReadInputTokens"])
                    bucket.cacheCreationInputTokens = combine(bucket.cacheCreationInputTokens, source["cacheCreationInputTokens"])
                    acc.modelUsage[model] = bucket
                }
                providers[providerID] = acc
            }
        }

        var out: [String: ProviderStats] = [:]
        for (id, acc) in providers {
            let providerDevices = acc.devices.sorted()
            out[id] = ProviderStats(
                providerId: id, providerName: acc.name, ready: acc.ready || !providerDevices.isEmpty,
                hasLocalStats: acc.hasLocalStats, hasPromptStats: acc.hasPromptStats, scope: nil,
                todayPrompts: acc.todayPrompts, todaySessions: acc.todaySessions, todayTotalTokens: acc.todayTotalTokens,
                todayTokensByModel: acc.todayTokensByModel,
                recentDays: dates.map { UsageRecord.RecentDay(date: $0, messageCount: acc.recentByDay[$0] ?? 0) },
                totalPrompts: acc.totalPrompts, totalSessions: acc.totalSessions,
                activeDays: max(acc.activeDays, acc.activeDates.count), activeDates: nil,
                modelUsage: acc.modelUsage, deviceCount: providerDevices.count, devices: providerDevices
            )
        }
        return Aggregate(deviceCount: devices.count, devices: devices.sorted(), providers: out)
    }

    /// `displayProvider` with synced stats: the local stats are replaced by the merged ones, while
    /// the record's limits, plan and balance stay this machine's.
    static func merged(_ record: UsageRecord, with stats: ProviderStats) -> UsageRecord {
        var display = record
        display.ready = true
        display.todayPrompts = stats.todayPrompts
        display.todaySessions = stats.todaySessions
        display.todayTotalTokens = stats.todayTotalTokens
        display.todayTokensByModel = stats.todayTokensByModel
        display.recentDays = stats.recentDays
        display.totalPrompts = stats.totalPrompts
        display.totalSessions = stats.totalSessions
        display.activeDays = stats.activeDays
        display.modelUsage = stats.modelUsage
        display.hasLocalStats = stats.hasLocalStats
        display.hasPromptStats = stats.hasPromptStats
        return display
    }

    /// `Math.round(Number(value || 0))`, 0 when that isn't a number.
    private static func number(_ value: Any?) -> Int {
        let n: Double
        switch value {
        case let number as NSNumber: n = number.doubleValue
        case let string as String: n = Double(string.trimmingCharacters(in: .whitespaces)) ?? .nan
        default: return 0
        }
        guard n.isFinite, abs(n) < 9e18 else { return 0 }
        return Int((n + 0.5).rounded(.down))
    }

    private static func truthyString(_ value: Any?) -> String? {
        PyNumber.truthyString(value)
    }
}

/// Runs the sync after records change, debounced by a second as `syncDebounce` is, one run at a
/// time, with a request that lands mid-run queued for one follow-up.
@MainActor
final class UsageSyncer {
    static let debounce: Duration = .seconds(1)

    private let settings: AppSettings
    private let model: PanelModel
    private var pending: Task<Void, Never>?
    private var running = false
    private var requestedWhileRunning = false

    init(settings: AppSettings, model: PanelModel) {
        self.settings = settings
        self.model = model
    }

    func schedule() {
        pending?.cancel()
        guard settings.syncConfigured else {
            model.setSync(nil, status: "")
            return
        }
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }

    private func run() async {
        guard settings.syncConfigured, let folder = settings.syncFolder else { return }
        if running {
            requestedWhileRunning = true
            return
        }
        running = true
        let fileName = UsageSync.safeSnapshotFileName(settings.syncFileName, deviceId: settings.syncDeviceId)
        let deviceId = UsageSync.effectiveDeviceId(settings.syncDeviceId, fileName: fileName)
        let now = Date()
        let snapshot = UsageSync.localSnapshot(records: model.localRecords.filter { settings.isEnabled($0.id) }, deviceId: deviceId, now: now)
        let (aggregate, status) = await Task.detached(priority: .utility) {
            UsageSync.writeAndScan(snapshot, folder: folder, fileName: fileName, now: now, calendar: .current)
        }.value
        if settings.syncConfigured { model.setSync(aggregate, status: status) }
        running = false
        if requestedWhileRunning {
            requestedWhileRunning = false
            schedule()
        }
    }
}
