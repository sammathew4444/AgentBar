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
    private var statusItemController: StatusItemController?
    private var refresher: UsageRefresher?
    private var watcher: RecordsWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = RecordStore()
        let model = PanelModel()
        let refresher = UsageRefresher(collector: ClaudeCollector(store: store), codex: CodexCollector(store: store))
        self.refresher = refresher

        let reload: @MainActor () -> Void = { [weak model] in
            model?.update(records: store.loadAll())
        }
        refresher.onRecordsChanged = reload
        watcher = RecordsWatcher(directory: store.directory, onChange: reload)
        reload()

        statusItemController = StatusItemController(
            model: model,
            theme: .tokyoNight,
            onPanelOpen: { [weak refresher] in refresher?.request(.panelOpened) },
            onRefresh: { [weak refresher] in refresher?.request(.forced) }
        )
        refresher.start()
    }
}
