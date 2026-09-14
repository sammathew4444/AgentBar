import AppKit

@main
@MainActor
enum AgentBarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private let model = PanelModel()
    private var themeStore: ThemeStore?
    private var syncer: UsageSyncer?
    private var statusItemController: StatusItemController?
    private var refresher: UsageRefresher?
    private var watcher: DirectoryWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        let themeStore = ThemeStore(themesDirectory: Bundle.main.url(forResource: "Themes", withExtension: nil))
        self.themeStore = themeStore
        syncer = UsageSyncer(settings: settings, model: model)
        model.setDisabledAgents(settings.disabledAgents)

        statusItemController = StatusItemController(
            model: model,
            themeStore: themeStore,
            settings: settings,
            onPanelOpen: { [weak self] in self?.refresher?.request(.panelOpened) },
            onRefresh: { [weak self] in self?.refresher?.request(.forced) }
        )
        settings.onChange = { [weak self] change in self?.apply(change) }
        startCollecting()
    }

    /// The store, collectors, refresher and records watcher, all on the current records folder.
    private func startCollecting() {
        refresher?.stop()
        watcher?.stop()

        let store = RecordStore(directory: settings.recordsDirectory)
        let refresher = UsageRefresher(
            collector: ClaudeCollector(store: store),
            others: [CodexCollector(store: store), GrokCollector(store: store)],
            intervalSeconds: settings.refreshInterval
        )
        refresher.isEnabled = { [weak settings] id in settings?.isEnabled(id) ?? true }
        self.refresher = refresher

        let reload: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.model.update(records: store.loadAll())
            self.syncer?.schedule()
        }
        refresher.onRecordsChanged = reload
        watcher = DirectoryWatcher(directory: store.directory, onChange: reload)
        reload()
        refresher.start()
    }

    private func apply(_ change: AppSettings.Change) {
        switch change {
        case .agents:
            model.setDisabledAgents(settings.disabledAgents)
            syncer?.schedule()
            refresher?.request(.forced)
        case .refreshInterval:
            refresher?.setInterval(seconds: settings.refreshInterval)
        case .showPercentage:
            statusItemController?.refreshButton()
        case .recordsFolder:
            startCollecting()
        case .sync:
            syncer?.schedule()
        }
    }

    /// An accessory app has no menu bar, but text fields still need ⌘X ⌘C ⌘V ⌘A and undo, which
    /// AppKit finds through the main menu's key equivalents.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}
