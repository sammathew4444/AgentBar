import AppKit
import OSLog

/// Owns the menu bar item and routes clicks and scrolls to their actions.
@MainActor
final class StatusItemController: NSObject {
    /// Accumulated trackpad scroll distance, in points, that counts as one cycle step.
    private static let trackpadScrollThreshold: CGFloat = 12

    private let statusItem: NSStatusItem
    private let panel = PanelController(theme: .tokyoNight)
    private var scrollMonitor: Any?
    private var scrollAccumulator: CGFloat = 0
    private var scrollGestureFired = false

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        installScrollMonitor()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        BarGlyph.apply(to: button)
        button.target = self
        button.action = #selector(buttonClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp, .otherMouseUp])
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
            cycleSubscription(step: 1)
        default:
            break
        }
    }

    // MARK: - Actions

    private func launchAgent() {
        Logger.statusItem.notice("Right click: launch agent (no-op until Phase 4)")
    }

    private func cycleSubscription(step: Int) {
        Logger.statusItem.notice("Cycle subscription by \(step, privacy: .public) (no-op until Phase 4)")
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
                cycleSubscription(step: event.scrollingDeltaY > 0 ? -1 : 1)
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
                cycleSubscription(step: scrollAccumulator > 0 ? -1 : 1)
            }
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            scrollAccumulator = 0
            scrollGestureFired = false
        }
    }
}
