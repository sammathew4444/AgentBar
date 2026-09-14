import AppKit
import OSLog
import QuartzCore
import SwiftUI

/// Borderless, non-activating panel that drops down from the status item.
/// Placement and fade follow Omarchy's KeyboardPanel (shell/Ui/KeyboardPanel.qml) for a top bar:
/// centred on the icon, `gapsOut` below the bar, clamped `gapsOut` from the screen edges.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    /// `Easing.OutCubic`.
    private static let fadeTiming = CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)
    /// A click on the status item that dismissed the panel via resign-key must not reopen it.
    private static let reopenDebounce: TimeInterval = 0.3

    private let panel: StatusPanel
    private let hostingView: NSHostingView<PanelView>
    private var outsideClickMonitor: Any?
    private var lastDismissal = Date.distantPast
    /// Logical open state. The window stays visible a little longer while it fades out.
    private var isOpen = false

    init(theme: OmarchyTheme) {
        hostingView = NSHostingView(rootView: PanelView(theme: theme))
        panel = StatusPanel(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Omarchy's layer-shell card casts no shadow.
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = hostingView
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
    }

    func toggle(below button: NSStatusBarButton) {
        if isOpen {
            close()
        } else if Date().timeIntervalSince(lastDismissal) > Self.reopenDebounce {
            open(below: button)
        }
    }

    private func open(below button: NSStatusBarButton) {
        guard let barWindow = button.window, let screen = barWindow.screen ?? NSScreen.main else { return }
        let anchor = barWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = hostingView.fittingSize
        let margin = OmarchyStyle.gapsOut
        let bounds = screen.frame

        var origin = NSPoint(x: anchor.midX - size.width / 2, y: barWindow.frame.minY - OmarchyStyle.gapsOut - size.height)
        origin.x = max(bounds.minX + margin, min(origin.x, bounds.maxX - margin - size.width))
        origin.y = max(bounds.minY + margin, origin.y)

        isOpen = true
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.setFrame(NSRect(origin: origin.rounded, size: size), display: true)
        panel.makeKeyAndOrderFront(nil)
        fade(to: 1)
        installOutsideClickMonitor()
        Logger.panel.debug("Panel opened")
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        lastDismissal = Date()
        removeOutsideClickMonitor()
        fade(to: 0) { [weak self] in
            guard let self, !self.isOpen else { return }
            self.panel.orderOut(nil)
        }
        Logger.panel.debug("Panel closed")
    }

    private func fade(to alpha: CGFloat, completion: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = OmarchyStyle.fadeDuration
            context.timingFunction = Self.fadeTiming
            panel.animator().alphaValue = alpha
        } completionHandler: {
            MainActor.assumeIsolated { completion?() }
        }
    }

    // MARK: - Dismissal

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    /// A non-activating panel doesn't reliably resign key when another app is clicked,
    /// so also close on any mouse-down delivered to other applications.
    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
    }
}

private extension NSPoint {
    /// KeyboardPanel rounds the card origin to whole pixels.
    var rounded: NSPoint { NSPoint(x: x.rounded(), y: y.rounded()) }
}

/// Borderless panels refuse key status by default; this one needs it so resign-key can dismiss it.
final class StatusPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
