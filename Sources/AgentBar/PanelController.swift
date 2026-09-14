import AppKit
import OSLog
import QuartzCore
import SwiftUI

/// Borderless, non-activating panel that drops down from the status item.
/// Placement and fade follow Omarchy's KeyboardPanel (shell/Ui/KeyboardPanel.qml) for a top bar:
/// centred on the icon, `gapsOut` below the bar, clamped `gapsOut` from the screen edges.
/// Keys follow PanelKeyCatcher as agents/Panel.qml wires it, and Dropdown while the theme list is open.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    /// `Easing.OutCubic`.
    private static let fadeTiming = CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)
    /// A click on the status item that dismissed the panel via resign-key must not reopen it.
    private static let reopenDebounce: TimeInterval = 0.3
    /// j/k scroll step, `Style.space(56)`.
    private static let scrollStep: CGFloat = 56
    /// The open panel re-reads the clock this often so countdowns stay true.
    private static let clockInterval: Duration = .seconds(30)

    /// Called each time the panel opens. Omarchy refreshes limits then (`onOpenedChanged`).
    var onOpen: (() -> Void)?
    /// r, Enter or Space: a refresh a person asked for (`refreshNow`).
    var onRefresh: (() -> Void)?
    /// The logical open state changed; the bar shows its open-panel indicator from this.
    var onOpenChange: ((Bool) -> Void)?

    private let model: PanelModel
    private let themeStore: ThemeStore
    private let panel: StatusPanel
    private let hostingView: SizeReportingHostingView<PanelView>
    private weak var anchorButton: NSStatusBarButton?
    private var outsideClickMonitor: Any?
    private var clockTask: Task<Void, Never>?
    private var lastDismissal = Date.distantPast
    /// Resizing the window re-lays out the content, which reports its size again.
    private var repositioning = false
    /// Logical open state. The window stays visible a little longer while it fades out.
    private(set) var isOpen = false

    init(model: PanelModel, themeStore: ThemeStore) {
        self.model = model
        self.themeStore = themeStore
        hostingView = SizeReportingHostingView(rootView: PanelView(model: model, themeStore: themeStore))
        hostingView.sizingOptions = [.intrinsicContentSize]
        panel = StatusPanel(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        hostingView.rootView = PanelView(model: model, themeStore: themeStore, onChooseFolder: { [weak self] in
            self?.chooseThemeFolder()
        })
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
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        hostingView.onIntrinsicSizeChange = { [weak self] in
            // In the same pass, before AppKit resizes the window from its bottom edge: a later
            // correction shows as the panel dropping and jumping back when content changes height.
            self?.reposition()
        }
    }

    func toggle(below button: NSStatusBarButton) {
        if isOpen {
            close()
        } else if Date().timeIntervalSince(lastDismissal) > Self.reopenDebounce {
            open(below: button)
        }
    }

    private func open(below button: NSStatusBarButton) {
        anchorButton = button
        isOpen = true
        onOpenChange?(true)
        model.cursorActive = false
        model.now = Date()
        model.maxContentHeight = Self.availableContentHeight(below: button)
        themeStore.reloadFolderTheme()
        if !panel.isVisible { panel.alphaValue = 0 }
        reposition()
        panel.makeKeyAndOrderFront(nil)
        scrollToTop()
        fade(to: 1)
        installOutsideClickMonitor()
        startClock()
        Logger.panel.debug("Panel opened")
        onOpen?()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        onOpenChange?(false)
        themeStore.closePicker()
        lastDismissal = Date()
        removeOutsideClickMonitor()
        clockTask?.cancel()
        clockTask = nil
        fade(to: 0) { [weak self] in
            guard let self, !self.isOpen else { return }
            self.panel.orderOut(nil)
        }
        Logger.panel.debug("Panel closed")
    }

    /// Room for the content between the gap under the menu bar and a margin above the Dock or
    /// the screen's bottom edge, less the card's insets.
    private static func availableContentHeight(below button: NSStatusBarButton) -> CGFloat {
        guard let barWindow = button.window, let screen = barWindow.screen ?? NSScreen.main else { return .infinity }
        let top = min(barWindow.frame.minY, screen.visibleFrame.maxY) - OmarchyStyle.gapsOut
        let bottom = screen.visibleFrame.minY + OmarchyStyle.gapsOut
        return max(120, top - bottom - PanelView.verticalInsets)
    }

    /// Sizes the panel to its content and places it under the icon, top edge fixed.
    private func reposition() {
        guard !repositioning, let button = anchorButton, let barWindow = button.window, let screen = barWindow.screen ?? NSScreen.main else { return }
        repositioning = true
        defer { repositioning = false }
        let anchor = barWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = hostingView.fittingSize
        let margin = OmarchyStyle.gapsOut
        let bounds = screen.frame

        var origin = NSPoint(x: anchor.midX - size.width / 2, y: barWindow.frame.minY - OmarchyStyle.gapsOut - size.height)
        origin.x = max(bounds.minX + margin, min(origin.x, bounds.maxX - margin - size.width))
        origin.y = max(bounds.minY + margin, origin.y)
        panel.setFrame(NSRect(origin: NSPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size), display: true)
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

    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.clockInterval)
                guard !Task.isCancelled else { return }
                self?.model.now = Date()
            }
        }
    }

    // MARK: - Theme folder

    /// "Custom folder…": a standard folder chooser. The app has to come forward for it, which
    /// closes the panel; the chosen theme applies straight away.
    private func chooseThemeFolder() {
        close()
        NSApp.activate()
        let chooser = NSOpenPanel()
        chooser.canChooseDirectories = true
        chooser.canChooseFiles = false
        chooser.allowsMultipleSelection = false
        chooser.prompt = "Use Theme"
        chooser.message = "Choose an Omarchy theme folder containing colors.toml."
        let omarchyThemes = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/omarchy/themes", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: omarchyThemes.path(percentEncoded: false)) { chooser.directoryURL = omarchyThemes }
        chooser.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let folder = chooser.url, let self else { return }
                if !self.themeStore.useFolder(folder) {
                    let alert = NSAlert()
                    alert.messageText = "No colors.toml in “\(folder.lastPathComponent)”"
                    alert.informativeText = "Choose an Omarchy theme folder, such as one from ~/.config/omarchy/themes."
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        if themeStore.pickerOpen { return handlePickerKey(event) }
        switch event.keyCode {
        case 53: close()                      // Esc
        case 123: move(by: -1)                // ←
        case 124: move(by: 1)                 // →
        case 125: scroll(by: 1)               // ↓
        case 126: scroll(by: -1)              // ↑
        case 36, 76, 49: onRefresh?()         // Return, Enter, Space
        default:
            switch event.charactersIgnoringModifiers {
            case "h": move(by: -1)
            case "l": move(by: 1)
            case "j": scroll(by: 1)
            case "k": scroll(by: -1)
            case "r", "R": onRefresh?()
            default: return false
            }
        }
        return true
    }

    /// Dropdown's list: j/k and ↑/↓ walk, Enter picks, Esc closes the list and keeps the panel.
    private func handlePickerKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: themeStore.closePicker()
        case 125: themeStore.movePicker(by: 1)
        case 126: themeStore.movePicker(by: -1)
        case 36, 76:
            if themeStore.chooseHighlighted() { chooseThemeFolder() }
        default:
            switch event.charactersIgnoringModifiers {
            case "j": themeStore.movePicker(by: 1)
            case "k": themeStore.movePicker(by: -1)
            default: break
            }
        }
        // The open list owns the keyboard, as its ListView holds focus in Omarchy.
        return true
    }

    private func move(by step: Int) {
        model.cursorActive = true
        model.cycle(by: step)
        scrollToTop()
    }

    // MARK: - Scrolling

    private var scrollView: NSScrollView? {
        func find(_ view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView { return scrollView }
            for subview in view.subviews {
                if let found = find(subview) { return found }
            }
            return nil
        }
        return find(hostingView)
    }

    private func scroll(by steps: Int) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maxY = max(0, document.frame.height - clip.bounds.height)
        let delta = CGFloat(steps) * Self.scrollStep * (document.isFlipped ? 1 : -1)
        let y = min(maxY, max(0, clip.bounds.origin.y + delta))
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    private func scrollToTop() {
        guard let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let top = document.isFlipped ? 0 : max(0, document.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: top))
        scrollView.reflectScrolledClipView(clip)
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

/// Tells the controller when SwiftUI's content changes size, so the panel can follow it.
final class SizeReportingHostingView<Content: View>: NSHostingView<Content> {
    var onIntrinsicSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIntrinsicSizeChange?()
    }
}

/// Borderless panels refuse key status by default; this one needs it for keys and resign-key.
final class StatusPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Keys go to the controller first, so an open theme list can take Esc for itself.
    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}
