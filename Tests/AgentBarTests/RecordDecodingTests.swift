import Foundation
import Testing
@testable import AgentBar

@Suite("Usage record decoding")
struct RecordDecodingTests {
    private func decode(_ json: String) throws -> UsageRecord {
        try RecordStore.decode(Data(json.utf8))
    }

    // MARK: - Captured records

    @Test(
        "Every record captured from Omarchy decodes",
        .enabled(if: !TestPaths.capturedRecords.isEmpty, "reference/records/ has no captured records yet")
    )
    func capturedRecordsDecode() throws {
        for url in TestPaths.capturedRecords {
            let record = try RecordStore.decode(Data(contentsOf: url))
            // omarchy-agent-usage-update writes each record to <agent id>.json.
            #expect(record.id == url.deletingPathExtension().lastPathComponent, "\(url.lastPathComponent)")
            #expect(record.schemaVersion == 1, "\(url.lastPathComponent)")
            let reencoded = try RecordStore.decode(JSONEncoder().encode(record))
            #expect(reencoded == record, "\(url.lastPathComponent) round-trips")
        }
    }

    // MARK: - Fixtures

    @Test("Fixture records decode and round-trip", arguments: ["claude", "codex", "fireworks"])
    func fixtureRoundTrip(name: String) throws {
        let record = try RecordStore.decode(TestPaths.fixture(name))
        #expect(record.id == name)
        #expect(record.schemaVersion == 1)
        #expect(try RecordStore.decode(JSONEncoder().encode(record)) == record)
    }

    // MARK: - Malformed input

    @Test("Input that isn't a JSON object is rejected")
    func notAnObject() {
        #expect(throws: (any Error).self) { try decode("not json") }
        #expect(throws: (any Error).self) { try decode("[]") }
        #expect(throws: (any Error).self) { try decode("\"claude\"") }
        #expect(throws: (any Error).self) { try decode("") }
    }

    @Test("A record without an id is rejected, as Main.qml skips it")
    func missingID() {
        #expect(throws: UsageRecord.RecordError.missingID) { try decode("{}") }
        #expect(throws: UsageRecord.RecordError.missingID) { try decode(#"{"id":"","name":"Claude Code"}"#) }
        #expect(throws: UsageRecord.RecordError.missingID) { try decode(#"{"id":42}"#) }
    }

    @Test("A bare record takes the panel's defaults")
    func defaults() throws {
        let record = try decode(#"{"id":"claude"}"#)
        #expect(record.name == "claude")
        #expect(record.schemaVersion == 0)
        #expect(record.ready == false)
        #expect(record.hasLocalStats == true)
        #expect(record.hasPromptStats == true)
        #expect(record.scope == "device")
        #expect(record.retryAdvised == false)
        #expect(record.limits.isEmpty)
        #expect(record.balance == nil)
        #expect(record.recentDays.isEmpty)
        #expect(record.modelUsage.isEmpty)
        #expect(record.totalPrompts == 0)
    }

    @Test("Mistyped fields fall back to defaults instead of failing the record")
    func mistypedFields() throws {
        let record = try decode("""
        {"id":"claude","name":7,"ready":"yes","todayPrompts":"12","totalPrompts":3.6,
         "limits":"none","modelUsage":[1,2],"recentDays":{"date":"2026-09-14"},"activeDates":["2026-09-14",5],
         "todayTokensByModel":{"claude-opus-5":1200.4,"bad":"x"}}
        """)
        #expect(record.name == "claude")
        #expect(record.ready == false)
        #expect(record.todayPrompts == 12)
        #expect(record.totalPrompts == 4)
        #expect(record.limits.isEmpty)
        #expect(record.modelUsage.isEmpty)
        #expect(record.recentDays.isEmpty)
        #expect(record.activeDates == ["2026-09-14"])
        #expect(record.todayTokensByModel == ["claude-opus-5": 1200])
    }

    @Test("Unusable limits are dropped one by one")
    func lossyLimits() throws {
        let record = try decode("""
        {"id":"claude","limits":[
          {"label":"Session (5-hour)","percent":0.5,"resetsAt":"2026-09-14T15:00:00+00:00"},
          {"label":"No percent"},
          {"label":"Text percent","percent":"high"},
          {"label":"Negative","percent":-1},
          "Weekly (7-day)",
          {"percent":0.25}
        ]}
        """)
        #expect(record.limits == [
            .init(label: "Session (5-hour)", percent: 0.5, resetsAt: "2026-09-14T15:00:00+00:00"),
            .init(label: "", percent: 0.25),
        ])
    }

    @Test("A balance without a usable remaining amount is no balance")
    func invalidBalance() throws {
        #expect(try decode(#"{"id":"fireworks","balance":{"funded":20}}"#).balance == nil)
        #expect(try decode(#"{"id":"fireworks","balance":{"remaining":-1,"funded":20}}"#).balance == nil)
        #expect(try decode(#"{"id":"fireworks","balance":"$12"}"#).balance == nil)
    }

    @Test("Balance amounts are clamped the way balanceValue does")
    func balanceClamping() throws {
        let balance = try #require(try decode(#"{"id":"fireworks","balance":{"remaining":12.5,"funded":-3,"spent":-1}}"#).balance)
        #expect(balance == .init(remaining: 12.5, funded: 0, spent: 0, currency: "USD", estimated: false))
    }

    // MARK: - Schema version

    @Test("An unknown schemaVersion decodes the fields it shares with version 1")
    func unknownSchemaVersion() throws {
        let record = try decode("""
        {"schemaVersion":2,"id":"claude","name":"Claude Code","ready":true,
         "futureField":{"nested":[1,2,3]},
         "limits":[{"label":"Session (5-hour)","percent":0.3,"resetsAt":"","futureLimitField":true}],
         "modelUsage":{"claude-opus-5":{"inputTokens":10,"outputTokens":5,"futureTokens":99}}}
        """)
        #expect(record.schemaVersion == 2)
        #expect(record.name == "Claude Code")
        #expect(record.ready)
        #expect(record.limits == [.init(label: "Session (5-hour)", percent: 0.3)])
        #expect(record.modelUsage["claude-opus-5"] == .init(inputTokens: 10, outputTokens: 5))
    }
}
