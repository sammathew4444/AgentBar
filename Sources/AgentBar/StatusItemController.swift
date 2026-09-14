import AppKit
import OSLog

/// Owns the menu bar item. Mirrors the BarIconButton in agents/Panel.qml: left click toggles the
/// panel, right click launches the agent, middle click moves to the next subscription, and the
/// glyph takes the urgent colour while the selected subscription is alarming. Scrolling also
/// cycles, as the trackpad's stand-in for a middle click.
@MainActor
final class StatusItemController: NSObject {
    /// Accumulated trackpad scroll distance, in points, that counts as one cycle step.
    private static let trackpadScrollThreshold: CGFloat = 12

    private let statusItem: NSStatusItem
    private let model: PanelModel
    private let themeStore: ThemeStore
    private let settings: AppSettings
    private let panel: PanelController
    private let openIndicator: OpenPanelIndicator
    private var scrollMonitor: Any?
    private var scrollAccumulator: CGFloat = 0
    private var scrollGestureFired = false

    init(model: PanelModel, themeStore: ThemeStore, settings: AppSettings, onPanelOpen: @escaping () -> Void, onRefresh: @escaping () -> Void) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.model = model
        self.themeStore = themeStore
        self.settings = settings
        panel = PanelController(model: model, themeStore: themeStore, settings: settings)
        openIndicator = OpenPanelIndicator(color: themeStore.current.accent.nsColor)
        super.init()
        panel.onOpen = onPanelOpen
        panel.onRefresh = onRefresh
        panel.onOpenChange = { [weak self] open in self?.openIndicator.setOpen(open) }
        model.onChange = { [weak self] in self?.refreshButton() }
        themeStore.onChange = { [weak self] in
            guard let self else { return }
            self.openIndicator.setColor(self.themeStore.current.accent.nsColor)
            self.refreshButton()
        }
        configureButton()
        installScrollMonitor()
        refreshButton()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(buttonClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp, .otherMouseUp])
        openIndicator.attach(to: button)
    }

    /// With nothing to report the module leaves the bar entirely, as Omarchy's does, unless
    /// agents were switched off here: then the robot stays so the settings stay reachable.
    func refreshButton() {
        let visible = !model.providers.isEmpty || !settings.disabledAgents.isEmpty
        if !visible { panel.close() }
        statusItem.isVisible = visible
        guard let button = statusItem.button else { return }
        let percentage = settings.showPercentage ? PanelLogic.bindingWindow(model.provider).map(PanelLogic.percentText) : nil
        BarGlyph.apply(to: button, color: model.alarming ? themeStore.current.urgent.nsColor : nil, text: percentage)
    }

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        switch event.type {
        case .leftMouseUp where event.modifierFlags.contains(.control):
            launchAgent()
        case .leftMouseUp:
            panel.toggle(below: sender)
        case .rightMouseUp:
            launchAgent()
        case .otherMouseUp where event.buttonNumber == 2:
            model.cycle(by: 1)
        default:
            break
        }
    }

    private func launchAgent() {
        panel.close()
        AgentLauncher.launch()
    }

    // MARK: - Scroll

    /// NSStatusBarButton doesn't forward scroll events to its target, so watch for them on its window.
    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleScroll(event)
            }
            return event
        }
    }

    private func handleScroll(_ event: NSEvent) {
        guard let buttonWindow = statusItem.button?.window, event.window === buttonWindow else { return }
        guard event.momentumPhase.isEmpty else { return }

        // Mouse wheel: every notch is one step.
        guard event.hasPreciseScrollingDeltas else {
            if event.scrollingDeltaY != 0 {
                model.cycle(by: event.scrollingDeltaY > 0 ? -1 : 1)
            }
            return
        }

        // Trackpad: one step per gesture, once the swipe travels far enough.
        if event.phase.contains(.began) {
            scrollAccumulator = 0
            scrollGestureFired = false
        }
        if !scrollGestureFired {
            scrollAccumulator += event.scrollingDeltaY
            if abs(scrollAccumulator) >= Self.trackpadScrollThreshold {
                scrollGestureFired = true
                model.cycle(by: scrollAccumulator > 0 ? -1 : 1)
            }
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            scrollAccumulator = 0
            scrollGestureFired = false
        }
    }
}
