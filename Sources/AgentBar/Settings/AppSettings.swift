import Foundation
import Observation

/// Settings, kept in UserDefaults. Omarchy's own come from the agents plugin's manifest.json
/// (`providers`, `refreshIntervalSec`, `syncMode`, `syncDir`, `syncFileName`, `syncDeviceId`);
/// the agent command, the percentage toggle, the records folder and launch at login are AgentBar's.
@MainActor
@Observable
final class AppSettings {
    struct Agent: Sendable, Equatable {
        let id: String
        let name: String
    }

    enum Change: Sendable {
        case agents, refreshInterval, showPercentage, recordsFolder, sync
    }

    enum Key {
        static let disabledAgents = "disabledAgents"
        static let refreshInterval = "refreshIntervalSec"
        static let showPercentage = "showPercentageInBar"
        static let recordsFolder = "recordsFolder"
        static let syncEnabled = "syncMode"
        static let syncFolder = "syncDir"
        static let syncFileName = "syncFileName"
        static let syncDeviceId = "syncDeviceId"
    }

    /// The agents AgentBar collects, in the order the panel lists them.
    static let agents = [
        Agent(id: ClaudeCollector.agentID, name: ClaudeCollector.agentName),
        Agent(id: CodexCollector.agentID, name: CodexCollector.agentName),
        Agent(id: GrokCollector.agentID, name: GrokCollector.agentName),
    ]
    /// The manifest's schema for `refreshIntervalSec`: 30 to 3600 in steps of 30, default 900.
    static let refreshRange = 30...3600
    static let refreshStep = 30
    static let defaultRefreshInterval = 900

    private(set) var disabledAgents: Set<String>
    private(set) var refreshInterval: Int
    private(set) var showPercentage: Bool
    private(set) var agentCommand: String
    /// Nil keeps records in Application Support.
    private(set) var recordsFolder: URL?
    private(set) var syncEnabled: Bool
    private(set) var syncFolder: URL?
    private(set) var syncFileName: String
    private(set) var syncDeviceId: String
    private(set) var launchAtLogin = false
    /// Why launch at login isn't simply on or off, when macOS says so.
    private(set) var loginItemNote = ""

    @ObservationIgnored var onChange: ((Change) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        disabledAgents = Set(defaults.stringArray(forKey: Key.disabledAgents) ?? [])
        refreshInterval = Self.snapped(defaults.object(forKey: Key.refreshInterval) as? Int ?? Self.defaultRefreshInterval)
        showPercentage = defaults.bool(forKey: Key.showPercentage)
        agentCommand = defaults.string(forKey: AgentLauncher.commandDefaultsKey) ?? ""
        recordsFolder = defaults.string(forKey: Key.recordsFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
        syncEnabled = defaults.bool(forKey: Key.syncEnabled)
        syncFolder = defaults.string(forKey: Key.syncFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
        syncFileName = defaults.string(forKey: Key.syncFileName) ?? ""
        syncDeviceId = defaults.string(forKey: Key.syncDeviceId) ?? ""
    }

    var recordsDirectory: URL { recordsFolder ?? RecordStore.defaultDirectory }

    /// `syncConfigured()` in Main.qml: switched on and pointed at a folder.
    var syncConfigured: Bool { syncEnabled && syncFolder != nil }

    func isEnabled(_ id: String) -> Bool { !disabledAgents.contains(id) }

    func setEnabled(_ id: String, _ enabled: Bool) {
        if enabled { disabledAgents.remove(id) } else { disabledAgents.insert(id) }
        defaults.set(disabledAgents.sorted(), forKey: Key.disabledAgents)
        onChange?(.agents)
    }

    func setRefreshInterval(_ seconds: Int) {
        let snapped = Self.snapped(seconds)
        guard snapped != refreshInterval else { return }
        refreshInterval = snapped
        defaults.set(snapped, forKey: Key.refreshInterval)
        onChange?(.refreshInterval)
    }

    func setShowPercentage(_ show: Bool) {
        showPercentage = show
        defaults.set(show, forKey: Key.showPercentage)
        onChange?(.showPercentage)
    }

    /// AgentLauncher reads the same key, so the next right click uses it.
    func setAgentCommand(_ command: String) {
        agentCommand = command
        defaults.set(command, forKey: AgentLauncher.commandDefaultsKey)
    }

    func setRecordsFolder(_ folder: URL?) {
        recordsFolder = folder
        defaults.set(folder?.path(percentEncoded: false), forKey: Key.recordsFolder)
        onChange?(.recordsFolder)
    }

    func setSyncEnabled(_ enabled: Bool) {
        syncEnabled = enabled
        defaults.set(enabled, forKey: Key.syncEnabled)
        onChange?(.sync)
    }

    func setSyncFolder(_ folder: URL?) {
        syncFolder = folder
        defaults.set(folder?.path(percentEncoded: false), forKey: Key.syncFolder)
        onChange?(.sync)
    }

    func setSyncFileName(_ name: String) {
        syncFileName = name
        defaults.set(name, forKey: Key.syncFileName)
        onChange?(.sync)
    }

    func setSyncDeviceId(_ id: String) {
        syncDeviceId = id
        defaults.set(id, forKey: Key.syncDeviceId)
        onChange?(.sync)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let error = LoginItem.set(enabled)
        refreshLoginItem()
        if let error { loginItemNote = error }
    }

    /// macOS owns the truth (the user can change it in System Settings), so it's read on open.
    func refreshLoginItem() {
        launchAtLogin = LoginItem.isEnabled
        loginItemNote = LoginItem.note
    }

    /// Clamped to the manifest's range and rounded to its step.
    static func snapped(_ seconds: Int) -> Int {
        let stepped = Int((Double(seconds) / Double(refreshStep)).rounded()) * refreshStep
        return min(refreshRange.upperBound, max(refreshRange.lowerBound, stepped))
    }
}
