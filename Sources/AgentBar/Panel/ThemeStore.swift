import Foundation
import Observation
import OSLog

/// The panel's theme: one of Omarchy's themes bundled with the app, or any folder holding an
/// Omarchy `colors.toml` (a theme synced from an Omarchy machine keeps following it). Also the
/// state of the theme list the palette button opens.
@MainActor
@Observable
final class ThemeStore {
    struct Bundled: Equatable, Sendable {
        let id: String
        let name: String
        let colorsFile: URL
    }

    enum Selection: Equatable {
        case bundled(String)
        case folder(URL)
    }

    struct Option: Identifiable, Equatable {
        enum Kind: Equatable {
            case bundled(String)
            case currentFolder
            case chooseFolder
        }

        let id: String
        let title: String
        let kind: Kind
    }

    static let defaultsKey = "theme"
    static let defaultThemeID = "tokyo-night"
    private static let folderPrefix = "folder:"

    private(set) var current: OmarchyTheme = .tokyoNight
    private(set) var selection: Selection = .bundled(ThemeStore.defaultThemeID)
    let bundled: [Bundled]

    /// The theme list is open, with the keyboard or mouse on `pickerIndex`.
    private(set) var pickerOpen = false
    var pickerIndex = 0

    /// Called after the theme changes, for what AppKit draws itself (the bar icon, its underline).
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var folderWatcher: DirectoryWatcher?

    init(themesDirectory: URL?, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bundled = Self.bundledThemes(in: themesDirectory)
        restore()
    }

    static func bundledThemes(in directory: URL?) -> [Bundled] {
        guard let directory,
              let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return entries.compactMap { entry -> Bundled? in
            let colors = entry.appending(path: "colors.toml")
            guard FileManager.default.fileExists(atPath: colors.path(percentEncoded: false)) else { return nil }
            let id = entry.lastPathComponent
            return Bundled(id: id, name: OmarchyTheme.displayName(forID: id), colorsFile: colors)
        }
        // `omarchy-theme-list` sorts by name.
        .sorted { $0.id < $1.id }
    }

    // MARK: - Choosing

    /// Omarchy's themes, the custom folder in use (if any), and a row to choose one.
    var options: [Option] {
        var options = bundled.map { Option(id: $0.id, title: $0.name, kind: .bundled($0.id)) }
        if case .folder(let folder) = selection {
            options.append(Option(id: "current-folder", title: "Custom: " + folder.lastPathComponent, kind: .currentFolder))
        }
        options.append(Option(id: "choose-folder", title: "Custom folder…", kind: .chooseFolder))
        return options
    }

    var currentOptionIndex: Int {
        let options = options
        switch selection {
        case .bundled(let id): return options.firstIndex { $0.kind == .bundled(id) } ?? 0
        case .folder: return options.firstIndex { $0.kind == .currentFolder } ?? 0
        }
    }

    func select(themeID id: String) {
        guard let entry = bundled.first(where: { $0.id == id }),
              let theme = Self.load(entry.colorsFile, id: id) else { return }
        stopWatchingFolder()
        selection = .bundled(id)
        defaults.set(id, forKey: Self.defaultsKey)
        apply(theme)
    }

    /// Uses the Omarchy theme in `folder`, and follows it as it changes. False without a colors.toml.
    @discardableResult
    func useFolder(_ folder: URL) -> Bool {
        guard let theme = Self.load(folder.appending(path: "colors.toml"), id: folder.lastPathComponent) else { return false }
        selection = .folder(folder)
        defaults.set(Self.folderPrefix + folder.path(percentEncoded: false), forKey: Self.defaultsKey)
        apply(theme)
        stopWatchingFolder()
        folderWatcher = DirectoryWatcher(directory: folder, createIfMissing: false) { [weak self] in
            self?.reloadFolderTheme()
        }
        return true
    }

    /// Re-reads a folder theme. Omarchy replaces the files on a switch, which the watcher sees;
    /// an edit in place isn't, so the panel also calls this when it opens.
    func reloadFolderTheme() {
        guard case .folder(let folder) = selection,
              let theme = Self.load(folder.appending(path: "colors.toml"), id: folder.lastPathComponent),
              theme != current else { return }
        apply(theme)
    }

    // MARK: - The list

    func togglePicker() {
        pickerOpen ? closePicker() : openPicker()
    }

    /// Opens on the current theme, as Dropdown's list starts on its value.
    func openPicker() {
        pickerIndex = currentOptionIndex
        pickerOpen = true
    }

    func closePicker() {
        pickerOpen = false
    }

    /// j/k and ↑/↓ stop at the ends, as in Dropdown.
    func movePicker(by step: Int) {
        pickerIndex = min(options.count - 1, max(0, pickerIndex + step))
    }

    /// Applies the row and closes the list. True when the row asks for a folder, which the
    /// caller prompts for.
    @discardableResult
    func choose(_ option: Option) -> Bool {
        closePicker()
        switch option.kind {
        case .bundled(let id):
            select(themeID: id)
            return false
        case .currentFolder:
            return false
        case .chooseFolder:
            return true
        }
    }

    @discardableResult
    func chooseHighlighted() -> Bool {
        let options = options
        guard options.indices.contains(pickerIndex) else {
            closePicker()
            return false
        }
        return choose(options[pickerIndex])
    }

    // MARK: - Private

    private func restore() {
        let saved = defaults.string(forKey: Self.defaultsKey) ?? Self.defaultThemeID
        if saved.hasPrefix(Self.folderPrefix) {
            let folder = URL(fileURLWithPath: String(saved.dropFirst(Self.folderPrefix.count)), isDirectory: true)
            if useFolder(folder) { return }
            Logger.panel.notice("Saved theme folder has no colors.toml; using the default")
        } else if bundled.contains(where: { $0.id == saved }) {
            select(themeID: saved)
            return
        }
        // Keep the saved preference; a missing folder may come back.
        if let entry = bundled.first(where: { $0.id == Self.defaultThemeID }), let theme = Self.load(entry.colorsFile, id: entry.id) {
            selection = .bundled(entry.id)
            apply(theme)
        }
    }

    private func apply(_ theme: OmarchyTheme) {
        current = theme
        onChange?()
    }

    private func stopWatchingFolder() {
        folderWatcher?.stop()
        folderWatcher = nil
    }

    private static func load(_ colorsFile: URL, id: String) -> OmarchyTheme? {
        guard let text = try? String(contentsOf: colorsFile, encoding: .utf8) else { return nil }
        return OmarchyTheme.parse(colorsToml: text, id: id)
    }
}
