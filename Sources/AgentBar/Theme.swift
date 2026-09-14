import AppKit
import SwiftUI

/// An sRGB colour from a theme value, with its own alpha (`rgba(RRGGBBAA)` borders carry one).
struct ThemeColor: Sendable, Equatable {
    let red: Double
    let green: Double
    let blue: Double
    var alpha: Double = 1

    init(hex: UInt32, alpha: Double = 1) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
        self.alpha = alpha
    }

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// The forms `canonicalColor` in shell/Commons/BorderGeometry.js accepts: `#rgb`,
    /// `#rrggbb[aa]`, `rgb(rrggbb)`, `rgba(rrggbbaa)`, `rgb(r,g,b)`, `rgba(r,g,b,a)`, `0xAARRGGBB`.
    init?(css raw: String) {
        let text = raw.trimmingCharacters(in: .whitespaces)
        func hex(_ digits: Substring) -> UInt32 { UInt32(digits, radix: 16) ?? 0 }
        func byte(_ digits: Substring) -> Double { min(255, max(0, Double(digits) ?? 0)) / 255 }
        if let m = text.wholeMatch(of: /#([0-9A-Fa-f])([0-9A-Fa-f])([0-9A-Fa-f])/) {
            self.init(hex: hex(m.1) * 0x110000 + hex(m.2) * 0x1100 + hex(m.3) * 0x11)
        } else if let m = text.wholeMatch(of: /#([0-9A-Fa-f]{6})([0-9A-Fa-f]{2})?/) {
            self.init(hex: hex(m.1), alpha: m.2.map { Double(hex($0)) / 255 } ?? 1)
        } else if let m = text.wholeMatch(of: /(?i)rgb\(([0-9A-F]{6})\)/) {
            self.init(hex: hex(m.1))
        } else if let m = text.wholeMatch(of: /(?i)rgba\(([0-9A-F]{6})([0-9A-F]{2})\)/) {
            self.init(hex: hex(m.1), alpha: Double(hex(m.2)) / 255)
        } else if let m = text.wholeMatch(of: /(?i)rgb\((\d+),(\d+),(\d+)\)/) {
            self.init(red: byte(m.1), green: byte(m.2), blue: byte(m.3))
        } else if let m = text.wholeMatch(of: /(?i)rgba\((\d+),(\d+),(\d+),([0-9.]+)\)/) {
            self.init(red: byte(m.1), green: byte(m.2), blue: byte(m.3), alpha: min(1, max(0, Double(m.4) ?? 1)))
        } else if let m = text.wholeMatch(of: /0x([0-9A-Fa-f]{2})([0-9A-Fa-f]{6})/) {
            self.init(hex: hex(m.2), alpha: Double(hex(m.1)) / 255)
        } else {
            return nil
        }
    }

    /// Qt's `darker(factor)`: HSV value divided by `factor` with hue and saturation kept,
    /// which scales every channel by the same amount.
    func darker(_ factor: Double) -> ThemeColor {
        ThemeColor(red: red / factor, green: green / factor, blue: blue / factor, alpha: alpha)
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    /// `Util.alpha(color, a)` / `Qt.rgba(c.r, c.g, c.b, a)`.
    func color(opacity: Double) -> Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity * alpha) }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    /// Relative luminance, as `colorLuminance` in agents/Panel.qml computes it.
    var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }
}

/// A solid colour or an Omarchy border gradient: colours spread evenly along `angle` degrees
/// (0 runs left to right, y points down), across the whole surface, as BorderOverlay draws it.
struct ThemePaint: Sendable, Equatable {
    var colors: [ThemeColor]
    var angle: Double = 0

    static func solid(_ color: ThemeColor) -> ThemePaint { ThemePaint(colors: [color]) }

    /// `parseGradientSpec`: whitespace-separated colours and an optional `Ndeg`. A part naming
    /// a theme colour resolves to it, as `resolve_gradient_color` does when a theme is set.
    init?(spec: String, references: [String: String] = [:]) {
        var colors: [ThemeColor] = []
        var angle = 0.0
        for part in spec.split(whereSeparator: \.isWhitespace) {
            if let m = part.wholeMatch(of: /(-?\d+(?:\.\d+)?)deg/) {
                angle = Double(m.1) ?? 0
                continue
            }
            if let color = ThemeColor(css: references[String(part)] ?? String(part)) { colors.append(color) }
        }
        guard !colors.isEmpty else { return nil }
        self.init(colors: colors, angle: angle)
    }

    init(colors: [ThemeColor], angle: Double = 0) {
        self.colors = colors
        self.angle = angle
    }

    var first: ThemeColor { colors[0] }
    var isGradient: Bool { colors.count > 1 }

    /// `gradientEndpoints` in unit coordinates of a `width` × `height` box.
    func endpoints(width: CGFloat, height: CGFloat) -> (start: UnitPoint, end: UnitPoint) {
        let w = max(1, Double(width)), h = max(1, Double(height))
        let radians = angle * .pi / 180
        let dx = cos(radians), dy = sin(radians)
        let length = (abs(w * dx) + abs(h * dy)) / 2
        return (
            UnitPoint(x: (w / 2 - dx * length) / w, y: (h / 2 - dy * length) / h),
            UnitPoint(x: (w / 2 + dx * length) / w, y: (h / 2 + dy * length) / h)
        )
    }
}

/// The Omarchy palette as the agents panel uses it (shell/Commons/Color.qml, shell/plugins/agents/Panel.qml).
struct OmarchyTheme: Sendable, Equatable {
    /// The theme's folder name, `tokyo-night`.
    let id: String
    /// As `omarchy-theme-list` prints it, `Tokyo Night`.
    let name: String
    let foreground: ThemeColor
    let background: ThemeColor
    let accent: ThemeColor
    /// `red` (or `color1`) in colors.toml.
    let urgent: ThemeColor
    let muted: ThemeColor
    /// `hyprland_active_border`, when the theme sets one.
    let activeBorder: ThemePaint?

    /// `Color.popups.background`, `background-alpha = 1.0` in default/themed/shell.toml.tpl.
    var popupBackground: ThemeColor { background }
    /// `Color.popups.border`: `hyprland.active-border`, which falls back to `accent`.
    var popupBorder: ThemePaint { activeBorder ?? .solid(accent) }
    /// `Color.tooltip.border`: `hyprland.active-border-foreground`, which falls back to `foreground`.
    var tooltipBorder: ThemePaint { activeBorder ?? .solid(foreground) }
    /// `dim` in agents/Panel.qml: `Qt.darker(foreground, 1.55)`.
    var dim: ThemeColor { foreground.darker(1.55) }
    /// The dim of PanelHero and PanelSectionHeader: `Qt.darker(foreground, 1.4)`.
    var headerDim: ThemeColor { foreground.darker(1.4) }

    /// Omarchy's install default (install/user/theme.sh), from themes/tokyo-night/colors.toml.
    static let tokyoNight = OmarchyTheme(
        id: "tokyo-night",
        name: "Tokyo Night",
        foreground: ThemeColor(hex: 0xA9B1D6),
        background: ThemeColor(hex: 0x1A1B26),
        accent: ThemeColor(hex: 0x7AA2F7),
        urgent: ThemeColor(hex: 0xF7768E),
        muted: ThemeColor(hex: 0x414868),
        activeBorder: nil
    )

    /// `loadColors` in Color.qml: only `#rrggbb` values count; `red` or `color1` is urgent;
    /// `color0`/`color7`/`color4`/`color8` stand in for a missing background, foreground,
    /// accent and muted; anything unset keeps Color.qml's default. `hyprland_active_border`
    /// is read the way omarchy-theme-set-templates writes it into shell.toml.
    static func parse(colorsToml text: String, id: String) -> OmarchyTheme {
        var foreground = ThemeColor(hex: 0xCACCCC), background = ThemeColor(hex: 0x101315)
        var accent = ThemeColor(hex: 0xCACCCC), urgent = ThemeColor(hex: 0xA55555), muted = ThemeColor(hex: 0x707880)
        var loadedForeground = false, loadedBackground = false, foundAccent = false, foundMuted = false
        var color0: ThemeColor?, color4: ThemeColor?, color7: ThemeColor?, color8: ThemeColor?
        var values: [String: String] = [:]

        for line in text.split(whereSeparator: \.isNewline) {
            if let m = line.firstMatch(of: /^\s*([A-Za-z0-9_-]+)\s*=\s*["']([^"']*)["']/) {
                values[String(m.1)] = String(m.2)
            }
            guard let m = line.firstMatch(of: /^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/),
                  let color = ThemeColor(css: String(m.2)) else { continue }
            switch m.1 {
            case "foreground": foreground = color; loadedForeground = true
            case "background": background = color; loadedBackground = true
            case "accent": accent = color; foundAccent = true
            case "muted": muted = color; foundMuted = true
            case "color0": color0 = color
            case "color4": color4 = color
            case "color7": color7 = color
            case "color8": color8 = color
            case "red", "color1": urgent = color
            default: break
            }
        }
        if !loadedBackground, let color0 { background = color0 }
        if !loadedForeground, let color7 { foreground = color7 }
        if !foundAccent, let color4 { accent = color4 }
        if !foundMuted { muted = color8 ?? foreground }

        return OmarchyTheme(
            id: id, name: displayName(forID: id),
            foreground: foreground, background: background, accent: accent, urgent: urgent, muted: muted,
            activeBorder: values["hyprland_active_border"].flatMap { ThemePaint(spec: $0, references: values) }
        )
    }

    /// `omarchy-theme-list`: `sed -E 's/(^|-)([a-z])/\1\u\2/g; s/-/ /g'`.
    static func displayName(forID id: String) -> String {
        var name = ""
        var capitalise = true
        for character in id {
            name.append(capitalise && character.isASCII && character.isLowercase ? Character(character.uppercased()) : character)
            capitalise = character == "-"
        }
        return name.replacingOccurrences(of: "-", with: " ")
    }
}

/// Structural tokens from shell/Commons/Style.qml at their defaults
/// (font base-size 12, spacing scale 1) under the default Hyprland look (default/hypr/looknfeel.lua).
enum OmarchyStyle {
    /// What `monospace` resolves to in default/fontconfig/conf.avail/50-omarchy.conf.
    static let fontFamily = "JetBrainsMono Nerd Font"

    enum FontSize {
        static let caption: CGFloat = 10
        static let bodySmall: CGFloat = 11
        static let body: CGFloat = 12
        static let subtitle: CGFloat = 13
        static let title: CGFloat = 14
        static let heading: CGFloat = 16
        static let display: CGFloat = 24
        /// `Style.font.icon`, which defaults to `title`.
        static let icon: CGFloat = 14
    }

    /// `Style.cornerRadius`: Hyprland `decoration:rounding = 0`.
    static let cornerRadius: CGFloat = 0
    /// `Style.gapsOut`: half of Hyprland `general:gaps_out = 10`. KeyboardPanel uses it for both
    /// the bar-to-panel gap and the screen-edge margin.
    static let gapsOut: CGFloat = 5
    /// `Style.spacing.popupPadding`.
    static let popupPadding: CGFloat = 14
    /// KeyboardPanel's border fallback, `max(1, Style.space(2))`.
    static let popupBorderWidth: CGFloat = 2
    /// `contentWidth: Style.space(380)` in agents/Panel.qml.
    static let panelWidth: CGFloat = 380
    /// KeyboardPanel's opacity Behavior: 140 ms, `Easing.OutCubic`.
    static let fadeDuration: TimeInterval = 0.14

    static func font(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(fontFamily, fixedSize: size).weight(bold ? .bold : .regular)
    }
}

/// A border drawn inside its bounds, as Qt's Rectangle border and BorderOverlay's ring do,
/// solid or with the theme's gradient.
struct BorderRing: View {
    let paint: ThemePaint
    let width: CGFloat

    var body: some View {
        GeometryReader { geometry in
            if paint.isGradient {
                let ends = paint.endpoints(width: geometry.size.width, height: geometry.size.height)
                Rectangle().strokeBorder(
                    LinearGradient(colors: paint.colors.map(\.color), startPoint: ends.start, endPoint: ends.end),
                    lineWidth: width
                )
            } else {
                Rectangle().strokeBorder(paint.first.color, lineWidth: width)
            }
        }
        .allowsHitTesting(false)
    }
}
