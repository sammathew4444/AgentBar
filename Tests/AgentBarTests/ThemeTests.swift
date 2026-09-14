import Foundation
import SwiftUI
import Testing
@testable import AgentBar

@Suite("Themes")
struct ThemeTests {
    static let themes = TestPaths.repoRoot.appending(path: "reference/theme/themes", directoryHint: .isDirectory)

    private func theme(_ id: String) throws -> OmarchyTheme {
        OmarchyTheme.parse(colorsToml: try String(contentsOf: Self.themes.appending(path: "\(id)/colors.toml"), encoding: .utf8), id: id)
    }

    @Test("Tokyo Night parses to the built-in default")
    func tokyoNight() throws {
        #expect(try theme("tokyo-night") == .tokyoNight)
        #expect(OmarchyTheme.tokyoNight.popupBorder == .solid(ThemeColor(hex: 0x7AA2F7)))
        #expect(OmarchyTheme.tokyoNight.tooltipBorder == .solid(ThemeColor(hex: 0xA9B1D6)))
    }

    @Test("A theme's hyprland_active_border becomes the panel and tooltip border gradient")
    func gradientBorder() throws {
        let hackerman = try theme("hackerman")
        let expected = ThemePaint(colors: [ThemeColor(hex: 0x26A269, alpha: 238.0 / 255), ThemeColor(hex: 0x2EC27E, alpha: 238.0 / 255)], angle: 45)
        #expect(hackerman.popupBorder == expected)
        #expect(hackerman.tooltipBorder == expected)
        #expect(try theme("solitude").popupBorder.angle == 0)
        #expect(try theme("solitude").popupBorder.isGradient)
    }

    @Test("Every bundled theme parses, and light ones read as light surfaces")
    func allThemes() throws {
        let ids = try FileManager.default.contentsOfDirectory(atPath: Self.themes.path(percentEncoded: false)).sorted()
        #expect(ids.count == 22)
        for id in ids {
            let parsed = try theme(id)
            #expect(parsed.foreground != parsed.background, "\(id)")
        }
        #expect(try theme("catppuccin-latte").popupBackground.luminance >= 0.5)
        #expect(try theme("tokyo-night").popupBackground.luminance < 0.5)
    }

    @Test("loadColors fallbacks: colorN stand-ins and Color.qml's defaults")
    func legacyKeys() {
        let theme = OmarchyTheme.parse(colorsToml: """
        color0 = "#000000"
        color4 = "#0000ff"
        color7 = "#ffffff"
        color1 = "#ff0000"
        """, id: "legacy")
        #expect(theme.background == ThemeColor(hex: 0x000000))
        #expect(theme.foreground == ThemeColor(hex: 0xFFFFFF))
        #expect(theme.accent == ThemeColor(hex: 0x0000FF))
        #expect(theme.urgent == ThemeColor(hex: 0xFF0000))
        #expect(theme.muted == ThemeColor(hex: 0xFFFFFF))

        let empty = OmarchyTheme.parse(colorsToml: "", id: "empty")
        #expect(empty.urgent == ThemeColor(hex: 0xA55555))
        #expect(empty.activeBorder == nil)
    }

    @Test("A gradient part naming a theme colour resolves to it")
    func gradientReferences() {
        let theme = OmarchyTheme.parse(colorsToml: """
        accent = "#7aa2f7"
        foreground = "#a9b1d6"
        hyprland_active_border = "accent foreground 90deg"
        """, id: "refs")
        #expect(theme.popupBorder == ThemePaint(colors: [ThemeColor(hex: 0x7AA2F7), ThemeColor(hex: 0xA9B1D6)], angle: 90))
    }

    @Test("Colour forms canonicalColor accepts")
    func cssColors() {
        #expect(ThemeColor(css: "#abc") == ThemeColor(hex: 0xAABBCC))
        #expect(ThemeColor(css: "#7aa2f7") == ThemeColor(hex: 0x7AA2F7))
        #expect(ThemeColor(css: "#7aa2f780") == ThemeColor(hex: 0x7AA2F7, alpha: 128.0 / 255))
        #expect(ThemeColor(css: "rgb(7aa2f7)") == ThemeColor(hex: 0x7AA2F7))
        #expect(ThemeColor(css: "rgba(26a269ee)") == ThemeColor(hex: 0x26A269, alpha: 238.0 / 255))
        #expect(ThemeColor(css: "rgb(255,0,128)") == ThemeColor(red: 1, green: 0, blue: 128.0 / 255))
        #expect(ThemeColor(css: "rgba(255,0,0,0.5)") == ThemeColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        #expect(ThemeColor(css: "0x80ff0000") == ThemeColor(hex: 0xFF0000, alpha: 128.0 / 255))
        #expect(ThemeColor(css: "accent") == nil)
    }

    @Test("Gradient endpoints follow gradientEndpoints")
    func endpoints() {
        let flat = ThemePaint(colors: [ThemeColor(hex: 0), ThemeColor(hex: 0xFFFFFF)], angle: 0).endpoints(width: 380, height: 600)
        #expect(flat.start == UnitPoint(x: 0, y: 0.5))
        #expect(flat.end == UnitPoint(x: 1, y: 0.5))

        let diagonal = ThemePaint(colors: [ThemeColor(hex: 0), ThemeColor(hex: 0xFFFFFF)], angle: 45).endpoints(width: 380, height: 600)
        let length = (380 * cos(Double.pi / 4) + 600 * sin(Double.pi / 4)) / 2
        #expect(abs(diagonal.start.x - (190 - cos(Double.pi / 4) * length) / 380) < 1e-9)
        #expect(abs(diagonal.end.y - (300 + sin(Double.pi / 4) * length) / 600) < 1e-9)
    }

    @Test("Theme names as omarchy-theme-list prints them", arguments: [
        ("tokyo-night", "Tokyo Night"), ("catppuccin-latte", "Catppuccin Latte"), ("retro-82", "Retro 82"),
        ("rose-pine", "Rose Pine"), ("white", "White"),
    ])
    func names(id: String, name: String) {
        #expect(OmarchyTheme.displayName(forID: id) == name)
    }
}

@Suite("Theme store")
@MainActor
struct ThemeStoreTests {
    private func defaults() -> UserDefaults {
        let suite = "AgentBarTests.theme.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Starts on Tokyo Night with every Omarchy theme listed, then a custom folder row")
    func defaultsToTokyoNight() {
        let store = ThemeStore(themesDirectory: ThemeTests.themes, defaults: defaults())
        #expect(store.current.id == "tokyo-night")
        #expect(store.bundled.count == 22)
        #expect(store.options.first?.title == "Catppuccin")
        #expect(store.options.last?.kind == .chooseFolder)
    }

    @Test("A choice is applied and remembered")
    func choosingPersists() {
        let defaults = defaults()
        let store = ThemeStore(themesDirectory: ThemeTests.themes, defaults: defaults)
        var changes = 0
        store.onChange = { changes += 1 }
        store.select(themeID: "gruvbox")
        #expect(store.current.name == "Gruvbox")
        #expect(changes == 1)
        #expect(ThemeStore(themesDirectory: ThemeTests.themes, defaults: defaults).current.id == "gruvbox")
    }

    @Test("A folder with colors.toml is used and remembered; one without is refused")
    func folders() throws {
        let temp = try TemporaryDirectory()
        let folder = temp.url.appending(path: "my-theme", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        background = "#101010"
        foreground = "#eeeeee"
        accent = "#ff8800"
        """.write(to: folder.appending(path: "colors.toml"), atomically: true, encoding: .utf8)
        let defaults = defaults()
        let store = ThemeStore(themesDirectory: ThemeTests.themes, defaults: defaults)

        #expect(!store.useFolder(temp.url.appending(path: "nothing-here")))
        #expect(store.current.id == "tokyo-night")
        #expect(store.useFolder(folder))
        #expect(store.current.accent == ThemeColor(hex: 0xFF8800))
        #expect(store.options.contains { $0.title == "Custom: my-theme" && $0.kind == .currentFolder })

        let restored = ThemeStore(themesDirectory: ThemeTests.themes, defaults: defaults)
        #expect(restored.current.name == "My Theme")

        try """
        background = "#101010"
        foreground = "#eeeeee"
        accent = "#00ff00"
        """.write(to: folder.appending(path: "colors.toml"), atomically: true, encoding: .utf8)
        restored.reloadFolderTheme()
        #expect(restored.current.accent == ThemeColor(hex: 0x00FF00))
    }

    @Test("The list opens on the current theme, stops at its ends, and picks with Enter")
    func pickerKeys() {
        let store = ThemeStore(themesDirectory: ThemeTests.themes, defaults: defaults())
        store.openPicker()
        #expect(store.pickerOpen)
        #expect(store.options[store.pickerIndex].title == "Tokyo Night")

        store.movePicker(by: 1)
        #expect(store.options[store.pickerIndex].title == "Vantablack")
        #expect(!store.chooseHighlighted())
        #expect(!store.pickerOpen)
        #expect(store.current.id == "vantablack")

        store.openPicker()
        store.movePicker(by: -100)
        #expect(store.pickerIndex == 0)
        store.movePicker(by: 100)
        #expect(store.options[store.pickerIndex].kind == .chooseFolder)
        // "Custom folder…" asks the caller for a folder instead of changing the theme.
        #expect(store.chooseHighlighted())
        #expect(store.current.id == "vantablack")
    }
}
