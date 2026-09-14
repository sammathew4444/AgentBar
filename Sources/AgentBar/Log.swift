import OSLog

extension Logger {
    private static let subsystem = "dev.agentbar.AgentBar"

    static let statusItem = Logger(subsystem: subsystem, category: "status-item")
    static let panel = Logger(subsystem: subsystem, category: "panel")
}
