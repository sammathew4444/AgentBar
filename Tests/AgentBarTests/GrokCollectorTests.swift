import Foundation
import Testing
@testable import AgentBar

/// Grok, on the synthetic fixtures in Fixtures/local/grok, shaped like Grok 1.0.24's
/// `usage.json` and `logs/unified.jsonl`, with the clock fixed at 2026-09-14T15:00:00Z.
@Suite("Grok collector")
struct GrokCollectorTests {
    static let now = ClaudeLocalScannerTests.now
    static let utc = ClaudeLocalScannerTests.utc
    static let home = ClaudeLocalScannerTests.local.appending(path: "grok", directoryHint: .isDirectory)

    private func scanner(home: URL = Self.home, cache: URL) -> GrokLocalScanner {
        GrokLocalScanner(grokHome: home, cacheDirectory: cache, calendar: Self.utc)
    }

    @Test("Turns count on the day they ended, under their model, with cache taken out of input")
    func sessions() throws {
        let temp = try TemporaryDirectory()
        let stats = scanner(cache: temp.url).scanAll(now: Self.now)

        #expect(stats.recentDays == [
            .init(date: "2026-09-08", messageCount: 0),
            .init(date: "2026-09-09", messageCount: 0),
            .init(date: "2026-09-10", messageCount: 440),
            .init(date: "2026-09-11", messageCount: 0),
            .init(date: "2026-09-12", messageCount: 0),
            .init(date: "2026-09-13", messageCount: 220),
            .init(date: "2026-09-14", messageCount: 825),
        ])
        #expect(stats.modelUsage == [
            "grok-4.5": .init(inputTokens: 500, outputTokens: 60, cacheReadInputTokens: 100, cacheCreationInputTokens: 0),
            "grok-4.6-build": .init(inputTokens: 240, outputTokens: 75, cacheReadInputTokens: 500, cacheCreationInputTokens: 10),
        ])
        #expect(stats.todayPrompts == 2)
        #expect(stats.todaySessions == 2)
        #expect(stats.todayTotalTokens == 825)
        #expect(stats.todayTokensByModel == ["grok-4.6-build": 825])
        // The forked session's copy of turn 2 counts once; the subagent session isn't read.
        #expect(stats.totalPrompts == 4)
        #expect(stats.totalSessions == 3)
        #expect(stats.activeDates == ["2026-09-10", "2026-09-13", "2026-09-14"])
    }

    @Test("The newest logged credits config is the limit and the plan")
    func billing() throws {
        let billing = try #require(scanner(cache: FileManager.default.temporaryDirectory).latestBilling(now: Self.now))
        #expect(billing.tier == "X Premium")
        #expect(billing.limit == .init(label: "Weekly (7-day)", percent: 0.15, resetsAt: "2026-09-16T09:30:28.543958+00:00"))
        #expect(PanelLogic.limitWindows(UsageRecord(id: "grok", name: "Grok", limits: [billing.limit!])).first?.title == "Weekly")
    }

    @Test("A billing period that has ended is no limit, but the plan stays")
    func endedPeriod() throws {
        let later = Self.now.addingTimeInterval(3 * 86_400)
        let billing = try #require(scanner(cache: FileManager.default.temporaryDirectory).latestBilling(now: later))
        #expect(billing.limit == nil)
        #expect(billing.tier == "X Premium")
    }

    @Test("Billing periods are named by their length")
    func periodLabels() {
        let start = Self.now
        func label(_ days: Double) -> String { GrokLocalScanner.periodLabel(start: start, end: start.addingTimeInterval(days * 86_400)) }
        #expect(label(7) == "Weekly (7-day)")
        #expect(label(30) == "Monthly (30-day)")
        #expect(label(14) == "Credits (14-day)")
        #expect(GrokLocalScanner.periodLabel(start: nil, end: start) == "Credits")
    }

    @Test("The record carries the plan, the limit and the local stats")
    func record() async throws {
        let temp = try TemporaryDirectory()
        let collector = GrokCollector(
            store: RecordStore(directory: temp.url.appending(path: "records")),
            localScanner: scanner(cache: temp.url.appending(path: "cache")),
            now: { Self.now }
        )
        let record = await collector.run()

        #expect(record.id == "grok")
        #expect(record.name == "Grok")
        #expect(record.ready)
        #expect(record.tierLabel == "X Premium")
        #expect(record.usageStatusText == "")
        #expect(record.limits.map(\.percent) == [0.15])
        #expect(record.todayTotalTokens == 825)
        #expect(PanelLogic.heroMeta(record) == "X Premium")
        #expect(try collector.store.load(id: "grok") == record)
    }

    @Test("Without Grok there is nothing to show")
    func noGrok() async throws {
        let temp = try TemporaryDirectory()
        let collector = GrokCollector(
            store: RecordStore(directory: temp.url.appending(path: "records")),
            localScanner: scanner(home: temp.url.appending(path: "no-grok"), cache: temp.url.appending(path: "cache")),
            now: { Self.now }
        )
        let record = await collector.run()
        #expect(!record.ready)
        #expect(record.limits.isEmpty)
        #expect(!PanelLogic.providerHasData(record))
    }
}
