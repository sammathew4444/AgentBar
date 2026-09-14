import AppKit
import OSLog

/// Right click: open a terminal running the configured agent, as `omarchy-agent` does on Omarchy.
/// Like Omarchy, the agent starts in `~/Work` when that exists, since agents won't remember
/// trust for the home directory.
@MainActor
enum AgentLauncher {
    /// The agent command. Settings arrive in Phase 6; until then `defaults write` can change it.
    static let commandDefaultsKey = "agentLaunchCommand"
    static let defaultCommand = "claude"

    static var command: String {
        let configured = UserDefaults.standard.string(forKey: commandDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return configured.isEmpty ? defaultCommand : configured
    }

    static func launch() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let work = home.appending(path: "Work", directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        let directory = FileManager.default.fileExists(atPath: work.path(percentEncoded: false), isDirectory: &isDirectory) && isDirectory.boolValue ? work : home

        // Terminal runs a `.command` file in a new window. An interactive login shell picks up
        // the PATH from the user's zsh startup files, where `claude` usually lives.
        let script = """
        #!/bin/zsh -li
        cd -- \(shellQuoted(directory.path(percentEncoded: false))) || exit 1
        exec \(command)

        """
        let url = URL.cachesDirectory.appending(path: "AgentBar/launch-agent.command")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(script.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path(percentEncoded: false))
        } catch {
            Logger.statusItem.error("Couldn't write the launch script: \(String(describing: error), privacy: .public)")
            return
        }

        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            Logger.statusItem.error("Terminal.app not found")
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                Logger.statusItem.error("Couldn't open Terminal: \(String(describing: error), privacy: .public)")
            }
        }
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
