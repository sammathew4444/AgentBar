import Foundation
import Testing
@testable import AgentBar

@Suite("Claude usage endpoint")
struct ClaudeUsageAPITests {
    private func limits(_ json: String) throws -> [UsageRecord.Limit] {
        ClaudeUsageAPI.parseLimits(try JSONSerialization.jsonObject(with: Data(json.utf8)))
    }

    @Test("The request is exactly the one in reference/request.md")
    func request() {
        let request = ClaudeUsageAPI.request(accessToken: "test-token")
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request.httpBody == nil)
        #expect(request.timeoutInterval == 10)
        #expect(request.allHTTPHeaderFields == [
            "Authorization": "Bearer test-token",
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
        ])
    }

    /// The payload and expected output of Omarchy's
    /// test/shell.d/agent-usage-claude-limits-test.sh, first case.
    @Test("Omarchy's scoped-limits payload reads exactly as the collector reads it")
    func omarchyScopedPayload() throws {
        let result = try limits("""
        {
          "five_hour": { "utilization": 78.0 },
          "seven_day": { "utilization": 12.0 },
          "seven_day_opus": null,
          "limits": [
            { "kind": "session", "percent": 78, "scope": null },
            { "kind": "weekly_all", "percent": 12, "scope": null },
            { "kind": "weekly_scoped", "percent": 17, "resets_at": "2026-08-15T03:00:00+00:00",
              "scope": { "model": { "id": "claude-fable-5", "display_name": "Fable" }, "surface": null } },
            { "kind": "weekly_scoped", "percent": 99, "scope": { "model": { "display_name": "Fable" } } },
            { "kind": "five_hour_scoped", "percent": 95, "scope": { "model": { "display_name": "Fable" } } },
            { "kind": "weekly_scoped", "percent": 42, "scope": { "model": { "id": "claude-opus-5", "display_name": null } } },
            { "kind": "weekly_scoped", "percent": 5, "scope": { "model": { "display_name": "  " } } },
            { "kind": "weekly_scoped", "percent": "unknown", "scope": { "model": { "display_name": "Opus" } } }
          ]
        }
        """)
        let expected = try JSONDecoder().decode([UsageRecord.Limit].self, from: Data("""
        [{"label":"Session (5-hour)","percent":0.78,"resetsAt":""},{"label":"Weekly (7-day)","percent":0.12,"resetsAt":""},{"label":"Fable Weekly","title":"Fable Weekly","percent":0.17,"resetsAt":"2026-08-15T03:00:00+00:00"},{"label":"Fable Session","title":"Fable Session","percent":0.95,"resetsAt":""},{"label":"claude-opus-5 Weekly","title":"claude-opus-5 Weekly","percent":0.42,"resetsAt":""}]
        """.utf8))
        #expect(result == expected)
    }

    /// Omarchy's second case: a fraction-scaled payload stays on its own scale.
    @Test("Fractions stay fractions")
    func fractionPayload() throws {
        let result = try limits("""
        {"five_hour":{"utilization":0.78},"limits":[{"kind":"session","percent":0.78,"scope":null},
         {"kind":"weekly_scoped","percent":0.42,"scope":{"model":{"display_name":"Fable"}}}]}
        """)
        #expect(result.map(\.percent) == [0.78, 0.42])
    }

    @Test("seven_day_oauth_apps wins over seven_day unless it's empty")
    func weeklyBucketChoice() throws {
        #expect(try limits(#"{"seven_day_oauth_apps":{"utilization":40},"seven_day":{"utilization":10}}"#).map(\.percent) == [0.4])
        #expect(try limits(#"{"seven_day_oauth_apps":{},"seven_day":{"utilization":10}}"#).map(\.percent) == [0.1])
    }

    @Test("Percent strings, caps, and unusable values")
    func utilizationEdges() throws {
        #expect(try limits(#"{"five_hour":{"utilization":"37%"}}"#).map(\.percent) == [0.37])
        #expect(try limits(#"{"five_hour":{"utilization":150}}"#).map(\.percent) == [1.0])
        #expect(try limits(#"{"five_hour":{"utilization":null},"seven_day":{"utilization":true}}"#).isEmpty)
        #expect(try limits("[]").isEmpty)
    }

    @Test("Reset times normalise the way normalize_reset_at does")
    func resetTimes() {
        #expect(ClaudeUsageAPI.normalizeResetAt(nil) == "")
        #expect(ClaudeUsageAPI.normalizeResetAt(NSNull()) == "")
        #expect(ClaudeUsageAPI.normalizeResetAt("  ") == "")
        #expect(ClaudeUsageAPI.normalizeResetAt(NSNumber(value: 1_789_398_000)) == "2026-09-14T15:00:00+00:00")
        #expect(ClaudeUsageAPI.normalizeResetAt("1789398000000") == "2026-09-14T15:00:00+00:00")
        #expect(ClaudeUsageAPI.normalizeResetAt("1789398000500") == "2026-09-14T15:00:00.500000+00:00")
        #expect(ClaudeUsageAPI.normalizeResetAt("2026-09-14T15:00:00Z") == "2026-09-14T15:00:00+00:00")
        #expect(ClaudeUsageAPI.normalizeResetAt("2026-09-14T15:00:00.123456+00:00") == "2026-09-14T15:00:00.123456+00:00")
        #expect(ClaudeUsageAPI.normalizeResetAt("next week") == "next week")
    }

    @Test("HTTP outcomes carry the collector's help text")
    func httpOutcomes() {
        #expect(ClaudeUsageAPI.interpret(status: 429, retryAfter: "30", body: Data()) == .failed(
            helpText: "Anthropic's usage endpoint is rate limiting checks right now (retry after 30s). Local Claude Code stats are still shown.",
            transport: false, retryAfter: 30
        ))
        #expect(ClaudeUsageAPI.interpret(status: 429, retryAfter: nil, body: Data()) == .failed(
            helpText: "Anthropic's usage endpoint is rate limiting checks right now. Local Claude Code stats are still shown.",
            transport: false, retryAfter: nil
        ))
        #expect(ClaudeUsageAPI.interpret(status: 401, retryAfter: nil, body: Data()) == .failed(
            helpText: "Anthropic's usage endpoint returned status 401. Local Claude Code stats are still shown.",
            transport: false, retryAfter: nil
        ))
        #expect(ClaudeUsageAPI.interpret(status: 200, retryAfter: nil, body: Data("<html>".utf8)) == ClaudeUsageAPI.transportFailure)
        #expect(ClaudeUsageAPI.interpret(status: 200, retryAfter: nil, body: Data("{}".utf8)) == .failed(
            helpText: "Anthropic's usage endpoint returned no limits. Local Claude Code stats are still shown.",
            transport: false, retryAfter: nil
        ))
    }

    @Test("updatedAt is written in Python's isoformat shape")
    func isoformat() {
        #expect(OmarchyDate.isoformat(Date(timeIntervalSince1970: 1_789_398_000)) == "2026-09-14T15:00:00+00:00")
        #expect(OmarchyDate.isoformat(Date(timeIntervalSince1970: 1_789_398_000.25)) == "2026-09-14T15:00:00.250000+00:00")
    }
}
