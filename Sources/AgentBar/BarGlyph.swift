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

    static func apply(to button: NSStatusBarButton) {
        if let font = NSFont(name: fontName, size: fontSize) {
            button.image = nil
            button.attributedTitle = NSAttributedString(string: robotGlyph, attributes: [.font: font])
        } else {
            Logger.statusItem.error("Bar font \(fontName, privacy: .public) not found; using placeholder icon")
            let image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "AgentBar")
            image?.isTemplate = true
            button.image = image
        }
    }
}
