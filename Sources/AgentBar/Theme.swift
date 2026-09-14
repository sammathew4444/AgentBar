import AppKit
import SwiftUI

/// An sRGB colour from a `#rrggbb` theme value.
struct ThemeColor: Sendable, Equatable {
    let red: Double
    let green: Double
    let blue: Double

    init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    private init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Qt's `darker(factor)`: HSV value divided by `factor` with hue and saturation kept,
    /// which scales every channel by the same amount.
    func darker(_ factor: Double) -> ThemeColor {
        ThemeColor(red: red / factor, green: green / factor, blue: blue / factor)
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }

    /// `Util.alpha(color, a)` / `Qt.rgba(c.r, c.g, c.b, a)`.
    func color(opacity: Double) -> Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity) }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    /// Relative luminance, as `colorLuminance` in agents/Panel.qml computes it.
    var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }
}

/// The Omarchy palette as the agents panel uses it (shell/Commons/Color.qml, shell/plugins/agents/Panel.qml).
struct OmarchyTheme: Sendable, Equatable {
    let foreground: ThemeColor
    let background: ThemeColor
    let accent: ThemeColor
    /// `red` in colors.toml.
    let urgent: ThemeColor
    /// `hyprland_active_border` in colors.toml, falling back to `accent`.
    let activeBorder: ThemeColor

    /// `Color.popups.background`, `background-alpha = 1.0` in default/themed/shell.toml.tpl.
    var popupBackground: ThemeColor { background }
    /// `Color.popups.border`: `hyprland.active-border` in default/themed/shell.toml.tpl.
    var popupBorder: ThemeColor { activeBorder }
    /// `dim` in agents/Panel.qml: `Qt.darker(foreground, 1.55)`.
    var dim: ThemeColor { foreground.darker(1.55) }
    /// The dim of PanelHero and PanelSectionHeader: `Qt.darker(foreground, 1.4)`.
    var headerDim: ThemeColor { foreground.darker(1.4) }
    /// `Color.tooltip.border`: `hyprland.active-border-foreground`, which falls back to `foreground`.
    var tooltipBorder: ThemeColor { hyprlandActiveBorderSet ? activeBorder : foreground }
    /// Whether colors.toml sets `hyprland_active_border`; without it both border roles fall back.
    var hyprlandActiveBorderSet: Bool { false }

    /// Omarchy's install default (install/user/theme.sh), from themes/tokyo-night/colors.toml.
    /// Phase 6 replaces this with a colors.toml parser.
    static let tokyoNight = OmarchyTheme(
        foreground: ThemeColor(hex: 0xA9B1D6),
        background: ThemeColor(hex: 0x1A1B26),
        accent: ThemeColor(hex: 0x7AA2F7),
        urgent: ThemeColor(hex: 0xF7768E),
        activeBorder: ThemeColor(hex: 0x7AA2F7)
    )
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
