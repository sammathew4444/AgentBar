import Foundation
import Testing
@testable import AgentBar

@Suite("Refresh gate")
struct RefreshGateTests {
    private let start = Date(timeIntervalSince1970: 1_789_398_000)

    @Test("Panel refreshes are floored at 15 s from the last run")
    func floor() {
        var gate = RefreshGate()
        #expect(gate.allowsPanelRefresh(at: start))
        gate.started(at: start)
        #expect(!gate.allowsPanelRefresh(at: start.addingTimeInterval(1)))
        #expect(!gate.allowsPanelRefresh(at: start.addingTimeInterval(14.9)))
        #expect(gate.allowsPanelRefresh(at: start.addingTimeInterval(15)))
    }

    @Test("No panel refresh before a 429's Retry-After has passed")
    func retryAfter() {
        var gate = RefreshGate()
        gate.started(at: start)
        gate.rateLimited(until: start.addingTimeInterval(120))
        #expect(!gate.allowsPanelRefresh(at: start.addingTimeInterval(60)))
        #expect(gate.allowsPanelRefresh(at: start.addingTimeInterval(120)))
    }

    @Test("A shorter Retry-After doesn't cut an earlier, longer one short")
    func longestWaitWins() {
        var gate = RefreshGate()
        gate.rateLimited(until: start.addingTimeInterval(300))
        gate.rateLimited(until: start.addingTimeInterval(30))
        #expect(!gate.allowsPanelRefresh(at: start.addingTimeInterval(60)))
    }
}
