import OSLog

extension Logger {
    private static let subsystem = "io.github.sammathew4444.AgentBar"

    static let statusItem = Logger(subsystem: subsystem, category: "status-item")
    static let panel = Logger(subsystem: subsystem, category: "panel")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let collector = Logger(subsystem: subsystem, category: "collector")
}
