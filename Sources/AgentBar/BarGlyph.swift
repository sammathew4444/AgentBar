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
    /// WidgetButton's label size, `Style.font.body`, for the optional percentage.
    static let labelSize: CGFloat = 12

    /// - Parameters:
    ///   - color: the bar's `active` colour while alarming. Nil gives a template image in the
    ///     menu bar's own colour: the macOS bar isn't painted with the theme background, so the
    ///     theme foreground wouldn't read on it.
    ///   - text: the percentage beside the robot, when that setting is on.
    static func apply(to button: NSStatusBarButton, color: NSColor? = nil, text: String? = nil) {
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

        guard let text else {
            button.title = ""
            button.imagePosition = .imageOnly
            return
        }
        let font = NSFont(name: fontName, size: labelSize) ?? .menuBarFont(ofSize: labelSize)
        if let color {
            button.attributedTitle = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        } else {
            // A plain title keeps the menu bar's own text colour in light and dark.
            button.title = text
            button.font = font
        }
        button.imagePosition = .imageLeading
    }

    /// The robot for the menu bar, centred by its outline, as OpticalGlyph does in Omarchy's bar.
    /// Nerd Font icons are wider than the advance they reserve, so centring the text would leave
    /// the robot off-centre, and the open-panel underline beneath it with it.
    static func image(color: NSColor?) -> NSImage? {
        centredImage(robotGlyph, fontSize: fontSize, canvas: canvas, color: color)
    }

    /// Any Nerd Font glyph drawn centred by its outline in a `canvas` square. Laid out as text, an
    /// icon overflows the advance it reserves and gets clipped by whatever sizes to that advance.
    /// Nil colour gives a template image, tinted by whoever shows it.
    static func centredImage(_ glyph: String, fontSize: CGFloat, canvas: CGFloat, color: NSColor?) -> NSImage? {
        guard let font = NSFont(name: fontName, size: fontSize) else { return nil }
        let text = NSAttributedString(string: glyph, attributes: [
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
