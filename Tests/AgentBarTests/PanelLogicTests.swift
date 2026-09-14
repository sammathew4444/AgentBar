import Foundation
import Testing
@testable import AgentBar

@Suite("Panel display rules")
struct PanelLogicTests {
    private func record(_ json: String) throws -> UsageRecord {
        try RecordStore.decode(Data(json.utf8))
    }

    @Test("Durations read like the panel's countdowns")
    func durations() {
        #expect(PanelLogic.formatDuration(0) == "now")
        #expect(PanelLogic.formatDuration(-5) == "now")
        #expect(PanelLogic.formatDuration(30_000) == "1m")
        #expect(PanelLogic.formatDuration(59 * 60_000) == "59m")
        #expect(PanelLogic.formatDuration(90 * 60_000) == "1h 30m")
        #expect(PanelLogic.formatDuration(26 * 3_600_000) == "1d 2h")
    }

    @Test("Window titles come out of free-text labels", arguments: [
        ("Session (5-hour)", "Session"),
        ("Weekly (7-day)", "Weekly"),
        ("5h window", "Session"),
        ("30m window", "Session"),
        ("Monthly spend", "Monthly"),
        ("30-day window", "Weekly"),
        // The reason collectors send explicit titles: "1M" reads as a one-minute window.
        ("Opus 5 (1M context)", "Session"),
        ("Custom (beta)", "Custom"),
        ("", "Limit"),
    ])
    func windowTitles(label: String, title: String) {
        #expect(PanelLogic.windowTitle(label) == title)
    }

    @Test("An explicit title wins, and the fullest window binds")
    func limitWindows() throws {
        let claude = try RecordStore.decode(TestPaths.fixture("claude"))
        let windows = PanelLogic.limitWindows(claude)
        #expect(windows.map(\.title) == ["Session", "Weekly", "Fable Weekly", "Fable Session", "claude-opus-5 Weekly"])
        #expect(PanelLogic.bindingWindow(claude)?.title == "Fable Session")
        #expect(PanelLogic.alarming(claude))
    }

    @Test("Percentages round to whole numbers")
    func percentText() {
        #expect(PanelLogic.percentText(.init(title: "", percent: 0.375, resetAt: "")) == "38%")
        #expect(PanelLogic.percentText(.init(title: "", percent: 0, resetAt: "")) == "0%")
        #expect(PanelLogic.percentText(.init(title: "", percent: 1, resetAt: "")) == "100%")
    }

    @Test("Reset lines count down, and vanish once the window has reset")
    func resetText() {
        let now = Date(timeIntervalSince1970: 1_789_398_000)
        #expect(PanelLogic.resetText(.init(title: "", percent: 0.1, resetAt: "2026-09-14T18:19:59.940755+00:00"), now: now) == "Resets in 3h 19m")
        #expect(PanelLogic.resetText(.init(title: "", percent: 0.1, resetAt: "2026-09-14T14:00:00+00:00"), now: now) == "")
        #expect(PanelLogic.resetText(.init(title: "", percent: 0.1, resetAt: ""), now: now) == "")
    }

    @Test("Alarm at 90% of a window or the last 10% of credit")
    func alarming() throws {
        #expect(PanelLogic.alarming(try record(#"{"id":"a","limits":[{"label":"x","percent":0.9}]}"#)))
        #expect(!PanelLogic.alarming(try record(#"{"id":"a","limits":[{"label":"x","percent":0.89}]}"#)))
        #expect(PanelLogic.alarming(try record(#"{"id":"a","balance":{"remaining":2,"funded":20}}"#)))
        #expect(!PanelLogic.alarming(try record(#"{"id":"a","balance":{"remaining":2.5,"funded":20}}"#)))
        #expect(!PanelLogic.alarming(nil))
    }

    @Test("Money and balance detail")
    func money() throws {
        #expect(PanelLogic.formatMoney(17.5, currency: "USD") == "$17.50")
        #expect(PanelLogic.formatMoney(3, currency: "eur") == "€3.00")
        #expect(PanelLogic.formatMoney(3, currency: "JPY") == "JPY 3.00")
        #expect(PanelLogic.formatMoney(3, currency: "") == "$3.00")
        let fireworks = try RecordStore.decode(TestPaths.fixture("fireworks"))
        #expect(PanelLogic.balanceDetailText(fireworks.balance) == "$2.50 spent of $20.00 funded · estimated")
        #expect(PanelLogic.balanceRatio(fireworks.balance) == 0.875)
    }

    @Test("The hero says the plan, or the problem")
    func heroMeta() throws {
        #expect(PanelLogic.heroMeta(try record(#"{"id":"a","tierLabel":"pro"}"#)) == "Pro")
        #expect(PanelLogic.heroMeta(try record(#"{"id":"a","tierLabel":"Max 20x"}"#)) == "Max 20x")
        #expect(PanelLogic.heroMeta(try record(#"{"id":"a"}"#)) == "Subscription")
        #expect(PanelLogic.heroMeta(try record(#"{"id":"a","tierLabel":"pro","usageStatusText":"Sign-in expired"}"#)) == "Sign-in expired")
    }

    @Test("Token counts", arguments: [(0, "0"), (999, "999"), (1000, "1.0K"), (251_000, "251.0K"), (1_500_000, "1.5M"), (2_000_000_000, "2.0B")])
    func tokenCounts(n: Int, text: String) {
        #expect(PanelLogic.formatTokenCount(n) == text)
    }

    @Test("Model names", arguments: [
        ("claude-opus-4-8", "Opus 4.8"),
        ("claude-haiku-4-5-20251001", "Haiku 4.5"),
        ("claude-sonnet-5", "Sonnet 5"),
        ("gpt-5.6-sol", "GPT 5.6 Sol"),
        ("deepseek-v3", "DeepSeek V3"),
        ("", "Unknown"),
    ])
    func modelNames(id: String, name: String) {
        #expect(PanelLogic.friendlyModelName(id) == name)
    }

    @Test("The four heaviest models, heaviest first")
    func modelRows() throws {
        let rows = PanelLogic.modelRows(try record("""
        {"id":"a","modelUsage":{
          "claude-a-1":{"inputTokens":1},"claude-b-1":{"inputTokens":5},"claude-c-1":{"outputTokens":3},
          "claude-d-1":{"cacheReadInputTokens":4},"claude-e-1":{"cacheCreationInputTokens":2}}}
        """))
        #expect(rows.map(\.name) == ["B 1", "D 1", "C 1", "E 1"])
        #expect(PanelLogic.modelTooltip(rows[1]) == "In 0 · out 0 · cache read 4 · cache write 0")
    }

    @Test("Days: names, today, and the tooltip's prompt counts")
    func days() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        let claude = try RecordStore.decode(TestPaths.fixture("claude"))
        let fireworks = try RecordStore.decode(TestPaths.fixture("fireworks"))
        let today = UsageRecord.RecentDay(date: "2026-09-14", messageCount: 251_000)

        #expect(PanelLogic.dayName("2026-09-14", calendar: calendar) == "Mon")
        #expect(PanelLogic.dayName("2026-13-40", calendar: calendar) == "2026-13-40")
        #expect(PanelLogic.dayLabel("2026-09-14", today: true, calendar: calendar) == "Today")
        #expect(PanelLogic.dayTooltip(today, today: true, record: claude, calendar: calendar) == "Mon 9/14 · 251.0K tokens · 42 prompts · 3 sessions")
        #expect(PanelLogic.dayTooltip(today, today: false, record: claude, calendar: calendar) == "Mon 9/14 · 251.0K tokens")
        #expect(PanelLogic.dayTooltip(today, today: true, record: fireworks, calendar: calendar) == "Mon 9/14 · 251.0K tokens")
        #expect(PanelLogic.todayDate(now: Date(timeIntervalSince1970: 1_789_398_000), calendar: calendar) == "2026-09-14")
        #expect(PanelLogic.weekPeak(claude) == 320_000)
    }

    @Test("Only agents with numbers get a tab")
    func providerHasData() throws {
        #expect(!PanelLogic.providerHasData(try record(#"{"id":"a","usageStatusText":"Waiting for auth"}"#)))
        #expect(PanelLogic.providerHasData(try record(#"{"id":"a","limits":[{"label":"x","percent":0}]}"#)))
        #expect(PanelLogic.providerHasData(try record(#"{"id":"a","todayPrompts":1}"#)))
        #expect(PanelLogic.providerHasData(try record(#"{"id":"a","balance":{"remaining":0}}"#)))
    }
}

@Suite("Panel model")
@MainActor
struct PanelModelTests {
    @Test("Selection follows the provider, wraps both ways, and ignores agents without data")
    func selection() throws {
        let model = PanelModel()
        let claude = try RecordStore.decode(TestPaths.fixture("claude"))
        let codex = try RecordStore.decode(TestPaths.fixture("codex"))
        let empty = try RecordStore.decode(Data(#"{"id":"idle"}"#.utf8))
        model.update(records: [claude, codex, empty])
        #expect(model.providers.map(\.id) == ["claude", "codex"])
        #expect(model.provider?.id == "claude")

        model.cycle(by: 1)
        #expect(model.provider?.id == "codex")
        model.cycle(by: 1)
        #expect(model.provider?.id == "claude")
        model.cycle(by: -1)
        #expect(model.provider?.id == "codex")

        // A provider landing in front of the selection doesn't move it.
        let fireworks = try RecordStore.decode(TestPaths.fixture("fireworks"))
        var first = fireworks
        first.id = "aaa"
        model.update(records: [first, claude, codex])
        #expect(model.provider?.id == "codex")
    }
}
