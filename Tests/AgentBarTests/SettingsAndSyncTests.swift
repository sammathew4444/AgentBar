import Foundation
import Testing
@testable import AgentBar

@Suite("Settings")
@MainActor
struct SettingsTests {
    private func defaults() -> UserDefaults {
        let suite = "AgentBarTests.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Defaults: every agent on, 900 s, no percentage, records in Application Support, sync off")
    func defaultsMatchTheManifest() {
        let settings = AppSettings(defaults: defaults())
        #expect(AppSettings.agents.map(\.id) == ["claude", "codex", "grok"])
        #expect(AppSettings.agents.allSatisfy { settings.isEnabled($0.id) })
        #expect(settings.refreshInterval == 900)
        #expect(!settings.showPercentage)
        #expect(settings.recordsDirectory == RecordStore.defaultDirectory)
        #expect(!settings.syncConfigured)
    }

    @Test("The refresh interval keeps to the manifest's range and step", arguments: [
        (10, 30), (30, 30), (47, 60), (899, 900), (1000, 990), (5000, 3600),
    ])
    func refreshInterval(input: Int, stored: Int) {
        let settings = AppSettings(defaults: defaults())
        settings.setRefreshInterval(input)
        #expect(settings.refreshInterval == stored)
    }

    @Test("Changes are remembered and announced")
    func persistence() {
        let defaults = defaults()
        let settings = AppSettings(defaults: defaults)
        var changes: [AppSettings.Change] = []
        settings.onChange = { changes.append($0) }
        settings.setEnabled("codex", false)
        settings.setRefreshInterval(300)
        settings.setShowPercentage(true)
        settings.setSyncEnabled(true)
        settings.setSyncFolder(URL(fileURLWithPath: "/tmp/sync", isDirectory: true))
        #expect(changes.count == 5)

        let restored = AppSettings(defaults: defaults)
        #expect(!restored.isEnabled("codex"))
        #expect(restored.isEnabled("claude"))
        #expect(restored.refreshInterval == 300)
        #expect(restored.showPercentage)
        #expect(restored.syncConfigured)
    }

    @Test("Disabled agents leave the panel")
    func disabledAgentsHidden() throws {
        let model = PanelModel()
        model.update(records: [try RecordStore.decode(TestPaths.fixture("claude")), try RecordStore.decode(TestPaths.fixture("codex"))])
        model.setDisabledAgents(["codex"])
        #expect(model.providers.map(\.id) == ["claude"])
        model.setDisabledAgents([])
        #expect(model.providers.map(\.id) == ["claude", "codex"])
    }
}

@Suite("Usage sync")
@MainActor
struct UsageSyncTests {
    static let now = ClaudeLocalScannerTests.now
    static let utc = ClaudeLocalScannerTests.utc

    private func snapshot(device: String, scope: String? = nil, prompts: Int, day14: Int, day10: Int = 0, dates: [String], models: [String: Int], name: String = "Claude Code", id: String = "claude") -> [String: Any] {
        var stats: [String: Any] = [
            "providerId": id, "providerName": name, "ready": true, "hasLocalStats": true, "hasPromptStats": true,
            "todayPrompts": prompts, "todaySessions": 1, "todayTotalTokens": day14, "todayTokensByModel": models,
            "recentDays": [["date": "2026-09-10", "messageCount": day10], ["date": "2026-09-14", "messageCount": day14], ["date": "2026-08-01", "messageCount": 99]],
            "totalPrompts": prompts * 10, "totalSessions": 3, "activeDays": dates.count, "activeDates": dates,
            "modelUsage": models.mapValues { ["inputTokens": $0, "outputTokens": 1] },
        ]
        if let scope { stats["scope"] = scope }
        return ["schemaVersion": 1, "deviceId": device, "updatedAt": "2026-09-14T12:00:00.000Z", "providers": [id: stats]]
    }

    @Test("Device stats add up, active days are unioned, and the week is this machine's")
    func deviceScopedSums() {
        let aggregate = UsageSync.aggregate([
            snapshot(device: "laptop", prompts: 2, day14: 100, day10: 5, dates: ["2026-09-10", "2026-09-14"], models: ["claude-opus-5": 100]),
            snapshot(device: "desktop", prompts: 3, day14: 50, dates: ["2026-09-14", "2026-09-13"], models: ["claude-opus-5": 30, "claude-sonnet-5": 20]),
        ], now: Self.now, calendar: Self.utc)

        #expect(aggregate.deviceCount == 2)
        #expect(aggregate.devices == ["desktop", "laptop"])
        let claude = aggregate.providers["claude"]!
        #expect(claude.todayPrompts == 5)
        #expect(claude.todayTotalTokens == 150)
        #expect(claude.totalPrompts == 50)
        #expect(claude.todayTokensByModel == ["claude-opus-5": 130, "claude-sonnet-5": 20])
        #expect(claude.modelUsage["claude-opus-5"] == .init(inputTokens: 130, outputTokens: 2))
        #expect(claude.recentDays.count == 7)
        #expect(claude.recentDays.first { $0.date == "2026-09-14" }?.messageCount == 150)
        #expect(claude.recentDays.first { $0.date == "2026-09-10" }?.messageCount == 5)
        #expect(claude.activeDays == 3)
        #expect(claude.deviceCount == 2)
    }

    @Test("Account-scoped stats take the widest value instead of summing")
    func accountScopeTakesMax() {
        let aggregate = UsageSync.aggregate([
            snapshot(device: "a", scope: "account", prompts: 4, day14: 10, dates: [], models: ["m": 10], name: "Fireworks", id: "fireworks"),
            snapshot(device: "b", scope: "account", prompts: 4, day14: 12, dates: [], models: ["m": 12], name: "Fireworks", id: "fireworks"),
        ], now: Self.now, calendar: Self.utc)
        let fireworks = aggregate.providers["fireworks"]!
        #expect(fireworks.todayTotalTokens == 12)
        #expect(fireworks.todayPrompts == 4)
    }

    @Test("Merged stats replace local ones, limits stay local, and other machines' agents appear")
    func displayMerge() throws {
        let model = PanelModel()
        model.update(records: [try RecordStore.decode(TestPaths.fixture("claude"))])
        let aggregate = UsageSync.aggregate([
            snapshot(device: "laptop", prompts: 2, day14: 100, dates: ["2026-09-14"], models: ["claude-opus-5": 100]),
            snapshot(device: "desktop", prompts: 1, day14: 7, dates: ["2026-09-14"], models: ["gpt-5.6-sol": 7], name: "Codex", id: "codex"),
        ], now: Self.now, calendar: Self.utc)
        model.setSync(aggregate, status: "")

        #expect(model.providers.map(\.id) == ["claude", "codex"])
        let claude = model.providers[0]
        #expect(claude.todayTotalTokens == 100)
        #expect(claude.limits.count == 5)
        #expect(model.footerText == "Merged from 1 device")
        model.select(1)
        #expect(model.provider?.limits.isEmpty == true)
        #expect(model.provider?.name == "Codex")

        model.setSync(nil, status: UsageSync.scanFailed)
        #expect(model.footerText == "Usage sync scan failed")
    }

    @Test("Names follow safeDeviceId and safeSnapshotFileName")
    func names() {
        #expect(UsageSync.safeDeviceId("Sam's MacBook Pro", hostname: "h") == "Sam-s-MacBook-Pro")
        #expect(UsageSync.safeDeviceId("  ", hostname: "studio") == "studio")
        #expect(UsageSync.safeDeviceId("..__", hostname: "") == "device")
        #expect(UsageSync.safeDeviceId(String(repeating: "a", count: 90), hostname: "h").count == 80)
        #expect(UsageSync.safeSnapshotFileName("", deviceId: "laptop", hostname: "h") == "laptop.json")
        #expect(UsageSync.safeSnapshotFileName("a/b/desk", deviceId: "", hostname: "h") == "desk.json")
        #expect(UsageSync.safeSnapshotFileName("Work.JSON", deviceId: "", hostname: "h") == "Work.JSON")
        #expect(UsageSync.effectiveDeviceId("", fileName: "laptop.json", hostname: "h") == "laptop")
    }

    @Test("A sync run writes this machine's snapshot and merges the folder, skipping bad files")
    func writeAndScan() throws {
        let temp = try TemporaryDirectory()
        let folder = temp.url.appending(path: "sync", directoryHint: .isDirectory)
        let records = [try RecordStore.decode(TestPaths.fixture("claude"))]
        let mine = UsageSync.localSnapshot(records: records, deviceId: "mac", now: Self.now)
        #expect(mine.providers["claude"]?.totalPrompts == 310)

        var (aggregate, status) = UsageSync.writeAndScan(mine, folder: folder, fileName: "mac.json", now: Self.now, calendar: Self.utc)
        #expect(status == "")
        #expect(aggregate?.deviceCount == 1)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "mac.json").path(percentEncoded: false)))

        let other = snapshot(device: "omarchy", prompts: 1, day14: 5, dates: ["2026-09-14"], models: ["claude-opus-5": 5])
        try JSONSerialization.data(withJSONObject: other).write(to: folder.appending(path: "omarchy.json"))
        try Data("[1,2,3]".utf8).write(to: folder.appending(path: "array.json"))
        try Data("{broken".utf8).write(to: folder.appending(path: "broken.json"))
        try Data(#"{"deviceId":"x"}"#.utf8).write(to: folder.appending(path: "no-providers.json"))

        (aggregate, status) = UsageSync.writeAndScan(mine, folder: folder, fileName: "mac.json", now: Self.now, calendar: Self.utc)
        #expect(aggregate?.deviceCount == 2)
        #expect(aggregate?.providers["claude"]?.totalPrompts == 310 + 10)
    }
}
