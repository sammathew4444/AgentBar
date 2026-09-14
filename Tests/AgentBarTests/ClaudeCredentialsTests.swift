import Foundation
import Testing
@testable import AgentBar

@Suite("Claude Code credentials")
struct ClaudeCredentialsTests {
    private let token = "fake-access-token-never-printed"

    private func item(_ login: String) -> Data {
        Data(#"{"claudeAiOauth":\#(login)}"#.utf8)
    }

    @Test("The Keychain item's JSON yields the token, expiry and plan")
    func parse() throws {
        let login = try #require(ClaudeLogin.parse(item(
            #"{"accessToken":"\#(token)","refreshToken":"r","expiresAt":1789401600000,"rateLimitTier":"default_claude_max_20x","subscriptionType":"max","scopes":["user:inference"]}"#
        )))
        #expect(login.accessToken == token)
        #expect(login.expiresAtMs == 1_789_401_600_000)
        #expect(login.plan == "Max 20x")
    }

    @Test("Plan labels follow plan_label", arguments: [
        ("default_claude_max_20x", "max", "Max 20x"),
        // re.IGNORECASE matches, but group(1) keeps the original case.
        ("DEFAULT_CLAUDE_MAX_5X", "", "Max 5X"),
        ("default_claude_ai", "pro", "Pro"),
        ("", "team", "Team"),
        ("", "", ""),
    ])
    func planLabels(tier: String, subscription: String, expected: String) {
        #expect(ClaudeLogin.planLabel(tier: tier, subscription: subscription) == expected)
    }

    @Test("Anything that isn't Claude Code's login is no login")
    func notALogin() {
        #expect(ClaudeLogin.parse(Data("not json".utf8)) == nil)
        #expect(ClaudeLogin.parse(Data(#"{"other":{}}"#.utf8)) == nil)
        #expect(ClaudeLogin.parse(Data(#"{"claudeAiOauth":"token"}"#.utf8)) == nil)
        #expect(ClaudeLogin.parse(item("{}"))?.accessToken == "")
    }

    @Test("The token never appears in descriptions or reflection")
    func redaction() throws {
        let login = try #require(ClaudeLogin.parse(item(#"{"accessToken":"\#(token)","expiresAt":1}"#)))
        var dumped = ""
        dump(login, to: &dumped)
        for text in [login.description, login.debugDescription, String(describing: login), String(reflecting: login), "\(login)", dumped] {
            #expect(!text.contains(token))
        }
    }

    @Test("Expiry compares epoch milliseconds with now")
    func expiry() {
        let now = Date(timeIntervalSince1970: 1_789_398_000)
        #expect(ClaudeLogin(accessToken: "t", expiresAtMs: 1_789_397_999_000, plan: "").isExpired(at: now))
        #expect(!ClaudeLogin(accessToken: "t", expiresAtMs: 1_789_398_001_000, plan: "").isExpired(at: now))
        #expect(!ClaudeLogin(accessToken: "t", expiresAtMs: 0, plan: "").isExpired(at: now))
    }

    @Test("security exit statuses map to distinct states")
    func securityStatuses() {
        #expect(SecurityCLIKeychain.result(status: 0, output: Data("{}\n".utf8)) == .found(Data("{}".utf8)))
        #expect(SecurityCLIKeychain.result(status: 44, output: Data()) == .notFound)
        #expect(SecurityCLIKeychain.result(status: 51, output: Data()) == .denied)
        #expect(SecurityCLIKeychain.result(status: 128, output: Data()) == .denied)
        #expect(SecurityCLIKeychain.result(status: 36, output: Data()) == .denied)
        #expect(SecurityCLIKeychain.result(status: 1, output: Data()) == .failed(status: 1))
    }
}
