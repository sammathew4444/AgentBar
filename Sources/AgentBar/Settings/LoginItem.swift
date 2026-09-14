import Foundation
import ServiceManagement

/// Launch at login through SMAppService, which the user can also switch in System Settings.
@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// What the settings row says when macOS needs something from the user.
    static var note: String {
        switch SMAppService.mainApp.status {
        case .requiresApproval: "Allow AgentBar in System Settings › General › Login Items."
        default: ""
        }
    }

    /// Nil on success, otherwise what went wrong.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
