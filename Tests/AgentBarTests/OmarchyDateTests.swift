import Foundation
import Testing
@testable import AgentBar

@Suite("Collector timestamps")
struct OmarchyDateTests {
    private let expected = Date(timeIntervalSince1970: 1_789_398_000) // 2026-09-14T15:00:00Z

    @Test("Python isoformat with microseconds and a +00:00 offset")
    func pythonIsoformat() {
        #expect(OmarchyDate.parse("2026-09-14T15:00:00.123456+00:00") == expected)
        #expect(OmarchyDate.parse("2026-09-14T15:00:00+00:00") == expected)
    }

    @Test("Z suffix and non-UTC offsets")
    func offsets() {
        #expect(OmarchyDate.parse("2026-09-14T15:00:00Z") == expected)
        #expect(OmarchyDate.parse("2026-09-14T17:00:00.5+02:00") == expected)
    }

    @Test("No offset reads as UTC")
    func naive() {
        #expect(OmarchyDate.parse("2026-09-14T15:00:00") == expected)
    }

    @Test("Empty and unparseable timestamps are nil", arguments: ["", "  ", "soon", "2026-09-14"])
    func unparseable(text: String) {
        #expect(OmarchyDate.parse(text) == nil)
    }
}
