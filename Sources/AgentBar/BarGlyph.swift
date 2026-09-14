import AppKit
import OSLog

/// The robot glyph shown in the menu bar.
@MainActor
enum BarGlyph {
    /// Omarchy's bar font is `monospace`, which Omarchy's fontconfig resolves to
    /// "JetBrainsMono Nerd Font" (default/fontconfig/conf.avail/50-omarchy.conf).
    static let fontName = "JetBrainsMonoNF-Regular"
    /// `md-robot_excited`, the `text` of the BarIconButton in shell/plugins/agents/Panel.qml.
    static let robotGlyph = "\u{F16A3}"
    /// `Style.bar.iconFont` default in shell/Commons/Style.qml.
    static let fontSize: CGFloat = 13

    /// - Parameter color: the bar's `active` colour while alarming. Nil leaves the glyph in the
    ///   menu bar's own text colour: the macOS bar isn't painted with the theme background, so
    ///   the theme foreground wouldn't read on it.
    static func apply(to button: NSStatusBarButton, color: NSColor? = nil) {
        if let font = NSFont(name: fontName, size: fontSize) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if let color { attributes[.foregroundColor] = color }
            button.image = nil
            button.attributedTitle = NSAttributedString(string: robotGlyph, attributes: attributes)
        } else {
            Logger.statusItem.error("Bar font \(fontName, privacy: .public) not found; using placeholder icon")
            let image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "AgentBar")
            image?.isTemplate = color == nil
            button.image = image
            button.contentTintColor = color
        }
    }
}
