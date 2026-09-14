import Foundation
import OSLog

/// Codex limits and plan, from the Codex app-server JSON-RPC exactly as omarchy-agent-usage-codex
/// asks for them (`fetch_codex_rpc`): `codex -s read-only -a on-request app-server`, then
/// `initialize`, the `initialized` notification, `account/read` and `account/rateLimits/read`, one
/// JSON object per line over stdio. AgentBar never reads Codex's credentials itself.
struct CodexAppServer: Sendable {
    struct Result: Sendable, Equatable {
        var limits: [UsageRecord.Limit] = []
        var tierLabel = ""
        var usageStatusText = ""
        var authHelpText = CodexCollector.authHelp
    }

    /// Where `codex` is looked for, first match wins.
    let searchPath: [String]
    /// The environment `codex` runs with. Its PATH includes `searchPath`, since codex is often a
    /// node script that needs node from the same places.
    let environment: [String: String]
    var initializeTimeout: TimeInterval = 8
    var requestTimeout: TimeInterval = 4

    /// `runtime_env` adds `~/.local/bin`, `~/.npm-global/bin` and mise's shims to PATH. An app
    /// opened from Finder gets a bare PATH, so Homebrew's directories are added too.
    static func live() -> CodexAppServer {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + [
            "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.local/share/mise/shims",
            "/opt/homebrew/bin", "/usr/local/bin",
        ]
        environment["PATH"] = path.filter { !$0.isEmpty }.joined(separator: ":")
        return CodexAppServer(searchPath: path, environment: environment)
    }

    func locate() -> URL? {
        for directory in searchPath where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appending(path: "codex")
            if FileManager.default.isExecutableFile(atPath: candidate.path(percentEncoded: false)) { return candidate }
        }
        return nil
    }

    /// Off the cooperative pool: talking to the child blocks for up to 16 s.
    func fetch() async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: fetchBlocking())
            }
        }
    }

    func fetchBlocking() -> Result {
        var result = Result()
        guard let codex = locate() else {
            result.usageStatusText = "Codex unavailable"
            result.authHelpText = "codex not found in PATH"
            return result
        }

        let process = Process()
        process.executableURL = codex
        process.arguments = ["-s", "read-only", "-a", "on-request", "app-server"]
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A child that exits early turns our next write into SIGPIPE; make that an error instead.
        signal(SIGPIPE, SIG_IGN)
        do {
            try process.run()
        } catch {
            result.usageStatusText = "Codex unavailable"
            result.authHelpText = error.localizedDescription
            return result
        }
        defer { Self.stop(process, input: input, output: output) }

        let session = RPCSession(input: input.fileHandleForWriting, output: output.fileHandleForReading)
        do {
            // Identifies this client to the local Codex process.
            _ = try session.request(id: 1, method: "initialize", params: ["clientInfo": ["name": "agentbar", "version": "1"]], timeout: initializeTimeout)
            try session.send(["method": "initialized", "params": [String: Any]()])
            let account = try session.request(id: 2, method: "account/read", timeout: requestTimeout)
            let limits = try session.request(id: 3, method: "account/rateLimits/read", timeout: requestTimeout)

            let accountInfo = (account["result"] as? [String: Any])?["account"] as? [String: Any] ?? [:]
            let rateLimits = (limits["result"] as? [String: Any])?["rateLimits"] as? [String: Any] ?? [:]
            result.tierLabel = PyNumber.truthyString(rateLimits["planType"])
                ?? PyNumber.truthyString(accountInfo["planType"])
                ?? PyNumber.truthyString(accountInfo["type"]) ?? ""
            result.limits = [rateLimits["primary"], rateLimits["secondary"]].compactMap(Self.limitWindow)
        } catch {
            result.usageStatusText = "Codex limits unavailable"
            // Python's str() of the collector's TimeoutError is the method that timed out.
            result.authHelpText = (error as? RPCSession.Failure)?.method ?? String(describing: error)
        }
        return result
    }

    /// `limit_window`: a window without `usedPercent` is no limit.
    static func limitWindow(_ value: Any?) -> UsageRecord.Limit? {
        guard let window = value as? [String: Any] else { return nil }
        let used: Double
        switch window["usedPercent"] {
        case let number as NSNumber: used = number.doubleValue
        case let string as String:
            guard let parsed = Double(string.trimmingCharacters(in: .whitespaces)) else { return nil }
            used = parsed
        default: return nil
        }
        let minutes = PyNumber.truncated(window["windowDurationMins"])
        let label = switch minutes {
        case 10080: "Weekly (7-day)"
        case let m where m != 0 && m % 60 == 0: "\(m / 60)h window"
        case let m where m != 0: "\(m)m window"
        default: "Limit"
        }
        let reset = window["resetsAt"]
        let resetsAt = PyNumber.truthyString(reset) == nil
            ? "" : OmarchyDate.isoformat(Date(timeIntervalSince1970: TimeInterval(PyNumber.truncated(reset))))
        return UsageRecord.Limit(label: label, percent: used / 100, resetsAt: resetsAt)
    }

    /// SIGTERM, a second to go, then SIGKILL.
    private static func stop(_ process: Process, input: Pipe, output: Pipe) {
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < deadline { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
    }
}

/// Line-delimited JSON-RPC over a child's stdio, with per-request deadlines (`rpc_request`).
private final class RPCSession {
    struct Failure: Error {
        let method: String
    }

    private let input: FileHandle
    private let descriptor: Int32
    private var buffer = Data()

    init(input: FileHandle, output: FileHandle) {
        self.input = input
        descriptor = output.fileDescriptor
    }

    /// Written as Python's `json.dumps` writes it, so `account/read` goes out as `account/read`.
    func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    /// Sends a request and returns the message carrying its id, skipping anything else the
    /// server says. No answer by the deadline, or the server gone, fails with the method.
    func request(id: Int, method: String, params: [String: Any] = [:], timeout: TimeInterval) throws -> [String: Any] {
        do {
            try send(["id": id, "method": method, "params": params])
        } catch {
            throw Failure(method: method)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while let line = readLine(until: deadline) {
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let messageID = message["id"] as? NSNumber,
                  CFGetTypeID(messageID) != CFBooleanGetTypeID(),
                  messageID.doubleValue == Double(id) else { continue }
            return message
        }
        throw Failure(method: method)
    }

    /// The next line, or nil on timeout or end of output.
    private func readLine(until deadline: Date) -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var descriptorPoll = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptorPoll, 1, Int32(min(remaining * 1000, Double(Int32.max)).rounded(.up)))
            if ready == 0 { return nil }
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = read(descriptor, &chunk, chunk.count)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
