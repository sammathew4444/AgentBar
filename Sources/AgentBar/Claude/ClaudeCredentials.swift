import Foundation
import OSLog

/// What Claude Code's login yields: the access token, its expiry, and the display-safe plan label
/// (`oauth_login` in omarchy-agent-usage-claude). The token goes nowhere but the Authorization
/// header of the usage request. `description`, `debugDescription` and `customMirror` leave it
/// out so it can't end up in a log by accident.
struct ClaudeLogin: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let accessToken: String
    /// Epoch milliseconds, 0 when unknown.
    let expiresAtMs: Int
    let plan: String

    var description: String { "ClaudeLogin(plan: \(plan), expiresAtMs: \(expiresAtMs), accessToken: <redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["plan": plan, "expiresAtMs": expiresAtMs]) }

    func isExpired(at now: Date) -> Bool {
        expiresAtMs > 0 && Double(expiresAtMs) <= now.timeIntervalSince1970 * 1000
    }

    /// Parses the Keychain item, which holds the same JSON Claude Code writes to
    /// `.credentials.json` on Linux. Nil when it isn't that shape.
    static func parse(_ data: Data) -> ClaudeLogin? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = root["claudeAiOauth"] as? [String: Any] else { return nil }
        return ClaudeLogin(
            accessToken: login["accessToken"] as? String ?? "",
            expiresAtMs: epochMilliseconds(login["expiresAt"]),
            plan: planLabel(tier: login["rateLimitTier"] as? String ?? "", subscription: login["subscriptionType"] as? String ?? "")
        )
    }

    /// `plan_label`: "…max_20x…" reads as "Max 20x", otherwise the subscription type capitalised.
    static func planLabel(tier: String, subscription: String) -> String {
        if let match = tier.firstMatch(of: /(?i)max_(\d+x)/) {
            return "Max " + match.1
        }
        guard let first = subscription.first else { return "" }
        return first.uppercased() + subscription.dropFirst()
    }

    private static func epochMilliseconds(_ value: Any?) -> Int {
        let n: Double
        switch value {
        case let number as NSNumber: n = number.doubleValue
        case let string as String: n = Double(string) ?? 0
        default: n = 0
        }
        return n.isFinite ? Int(n.rounded()) : 0
    }
}

enum KeychainResult: Sendable, Equatable {
    case found(Data)
    case notFound
    /// The user refused access, or macOS couldn't ask them.
    case denied
    case failed(status: Int32)
}

protocol KeychainReading: Sendable {
    func readClaudeCredentials() async -> KeychainResult
}

/// Reads Claude Code's Keychain item by running `/usr/bin/security`. The Keychain prompt is
/// then attributed to that system binary, and an "Always Allow" can be revoked in Keychain
/// Access. The secret comes back on stdout and is returned without being logged.
struct SecurityCLIKeychain: KeychainReading {
    static let service = "Claude Code-credentials"

    func readClaudeCredentials() async -> KeychainResult {
        // `security` blocks while the Keychain prompt is up, so keep it off the cooperative pool.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.run())
            }
        }
    }

    private static func run() -> KeychainResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Logger.collector.error("Couldn't run /usr/bin/security")
            return .failed(status: -1)
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return result(status: process.terminationStatus, output: output)
    }

    /// `security` exits with the low byte of the Security framework status.
    static func result(status: Int32, output: Data) -> KeychainResult {
        switch status {
        case 0:
            // `-w` prints the password followed by a newline.
            var data = output
            while let last = data.last, last == 0x0A || last == 0x0D { data.removeLast() }
            return .found(data)
        case 44: // errSecItemNotFound (-25300)
            return .notFound
        case 51, 128, 36: // errSecAuthFailed (-25293), errSecUserCanceled (-128), errSecInteractionNotAllowed (-25308)
            return .denied
        default:
            return .failed(status: status)
        }
    }
}
