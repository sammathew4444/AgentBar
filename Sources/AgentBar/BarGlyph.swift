import AppKit
import CoreText
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
    /// `Style.bar.iconCanvas`: the square the glyph is centred in.
    static let canvas: CGFloat = 16

    /// - Parameter color: the bar's `active` colour while alarming. Nil gives a template image in
    ///   the menu bar's own colour: the macOS bar isn't painted with the theme background, so the
    ///   theme foreground wouldn't read on it.
    static func apply(to button: NSStatusBarButton, color: NSColor? = nil) {
        button.title = ""
        button.imagePosition = .imageOnly
        if let image = image(color: color) {
            button.image = image
            button.contentTintColor = nil
        } else {
            Logger.statusItem.error("Bar font \(fontName, privacy: .public) not found; using placeholder icon")
            let image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "AgentBar")
            image?.isTemplate = color == nil
            button.image = image
            button.contentTintColor = color
        }
    }

    /// The glyph drawn centred by its outline, as OpticalGlyph does in Omarchy's bar. Nerd Font
    /// icons are wider than the advance they reserve, so centring the text would leave the robot
    /// off-centre, and the open-panel underline beneath it with it.
    static func image(color: NSColor?) -> NSImage? {
        guard let font = NSFont(name: fontName, size: fontSize) else { return nil }
        let text = NSAttributedString(string: robotGlyph, attributes: [
            .font: font,
            .foregroundColor: color ?? NSColor.black,
        ])
        let line = CTLineCreateWithAttributedString(text)
        let outline = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard !outline.isEmpty else { return nil }

        let size = NSSize(width: canvas, height: canvas)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.textPosition = CGPoint(x: size.width / 2 - outline.midX, y: size.height / 2 - outline.midY)
            CTLineDraw(line, context)
            return true
        }
        image.isTemplate = color == nil
        image.accessibilityDescription = "AgentBar"
        return image
    }
}
