import AppKit
import SwiftUI

/// What a folder chooser is for. Choosing needs an open panel, which the controller owns.
enum FolderPurpose: Sendable {
    case theme, records, sync
}

/// The settings page, drawn with Omarchy's own controls (shell/Ui/Toggle.qml, ToggleSwitch.qml,
/// TextField.qml, NumberField.qml). Omarchy's settings use the manifest's labels and descriptions
/// (shell/plugins/agents/manifest.json).
struct SettingsView: View {
    let settings: AppSettings
    let theme: OmarchyTheme
    let onChooseFolder: (FolderPurpose) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelSeparator(theme: theme)
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(text: "AGENTS", theme: theme)
                ForEach(AppSettings.agents, id: \.id) { agent in
                    OmarchyToggleRow(label: agent.name, checked: settings.isEnabled(agent.id), theme: theme) {
                        settings.setEnabled(agent.id, !settings.isEnabled(agent.id))
                    }
                }
            }

            PanelSeparator(theme: theme)
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(text: "GENERAL", theme: theme)
                OmarchyNumberField(
                    label: "Refresh interval (seconds)", value: settings.refreshInterval,
                    range: AppSettings.refreshRange, step: AppSettings.refreshStep, theme: theme
                ) { settings.setRefreshInterval($0) }
                OmarchyToggleRow(
                    label: "Show percentage in bar", description: "The fullest limit, next to the robot.",
                    checked: settings.showPercentage, theme: theme
                ) { settings.setShowPercentage(!settings.showPercentage) }
                OmarchyTextField(
                    label: "Agent command", description: "What a right click on the robot runs in Terminal.",
                    text: Binding(get: { settings.agentCommand }, set: { settings.setAgentCommand($0) }),
                    placeholder: AgentLauncher.defaultCommand, theme: theme
                )
                FolderField(
                    label: "Records folder", description: "Where usage records are kept. Omarchy-style collectors can write here too.",
                    path: Self.abbreviated(settings.recordsDirectory), placeholder: "", canReset: settings.recordsFolder != nil, theme: theme,
                    onChoose: { onChooseFolder(.records) }, onReset: { settings.setRecordsFolder(nil) }
                )
                OmarchyToggleRow(
                    label: "Launch at login", description: settings.loginItemNote,
                    checked: settings.launchAtLogin, theme: theme
                ) { settings.setLaunchAtLogin(!settings.launchAtLogin) }
            }

            PanelSeparator(theme: theme)
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(text: "SYNC", theme: theme)
                OmarchyToggleRow(
                    label: "Synced aggregation",
                    description: "When On, write this machine's local usage snapshot and merge snapshots from other machines.",
                    checked: settings.syncEnabled, theme: theme
                ) { settings.setSyncEnabled(!settings.syncEnabled) }
                FolderField(
                    label: "Sync folder", description: "A folder synced by Syncthing, Dropbox, rsync, etc.",
                    path: settings.syncFolder.map(Self.abbreviated) ?? "", placeholder: "Not set",
                    canReset: settings.syncFolder != nil, theme: theme,
                    onChoose: { onChooseFolder(.sync) }, onReset: { settings.setSyncFolder(nil) }
                )
                OmarchyTextField(
                    label: "Snapshot file name",
                    description: "Optional. Defaults to <hostname>.json. Use a different file name on each machine, such as laptop.json or desktop.json.",
                    text: Binding(get: { settings.syncFileName }, set: { settings.setSyncFileName($0) }),
                    placeholder: UsageSync.safeDeviceId("") + ".json", theme: theme
                )
                OmarchyTextField(
                    label: "Device id", description: "Optional stable device name used inside synced aggregate snapshots.",
                    text: Binding(get: { settings.syncDeviceId }, set: { settings.setSyncDeviceId($0) }),
                    placeholder: UsageSync.safeDeviceId(""), theme: theme
                )
            }

            // A menu bar app with no Dock icon and no menu needs its own way out.
            PanelSeparator(theme: theme)
            HStack {
                Spacer(minLength: 0)
                Button("Quit AgentBar") { NSApp.terminate(nil) }
                    .buttonStyle(OmarchyButtonStyle(theme: theme))
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
    }

    static func abbreviated(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        return path.hasPrefix(home) ? "~/" + path.dropFirst(home.count).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : path
    }
}

// MARK: - Omarchy controls

/// Toggle.qml: a bordered row, label in bold and an optional description, the switch at its end.
/// The whole row toggles.
struct OmarchyToggleRow: View {
    let label: String
    var description: String = ""
    let checked: Bool
    let theme: OmarchyTheme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(OmarchyStyle.font(OmarchyStyle.FontSize.subtitle, bold: true))
                        .foregroundStyle(theme.foreground.color)
                        .lineLimit(1)
                    if !description.isEmpty {
                        Text(description)
                            .font(OmarchyStyle.font(OmarchyStyle.FontSize.caption))
                            .foregroundStyle(theme.foreground.darker(1.5).color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                OmarchyToggleSwitch(checked: checked, theme: theme)
            }
            // Style.spacing.rowPaddingX beside, Style.spacing.huge split above and below.
            .padding(.horizontal, 12 + 1)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(theme.foreground.color(opacity: hovering ? 0.08 : 0.04))
            .overlay(Rectangle().strokeBorder(theme.foreground.color(opacity: hovering ? 0.25 : 0.4), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// ToggleSwitch.qml with square corners (Style.cornerRadius 0): a 42 × 22 track, 16-unit knob.
/// On, the selected fill and a foreground knob; off, the normal fill and border and a dim knob.
struct OmarchyToggleSwitch: View {
    let checked: Bool
    let theme: OmarchyTheme

    var body: some View {
        ZStack(alignment: checked ? .trailing : .leading) {
            Rectangle()
                .fill(theme.foreground.color(opacity: checked ? 0.18 : 0.04))
                .overlay(Rectangle().strokeBorder(theme.foreground.color(opacity: checked ? 0 : 0.4), lineWidth: 1))
            Rectangle()
                .fill((checked ? theme.foreground : theme.foreground.darker(1.25)).color)
                .frame(width: 16, height: 16)
                .padding(.horizontal, 3)
        }
        .frame(width: 42, height: 22)
    }
}

/// NumberField.qml's label: body-small, darkened foreground.
struct FieldLabel: View {
    let text: String
    let theme: OmarchyTheme

    var body: some View {
        Text(text)
            .font(OmarchyStyle.font(OmarchyStyle.FontSize.bodySmall))
            .foregroundStyle(theme.headerDim.color)
    }
}

/// A Toggle-style description under a field.
struct FieldDescription: View {
    let text: String
    let theme: OmarchyTheme

    var body: some View {
        Text(text)
            .font(OmarchyStyle.font(OmarchyStyle.FontSize.caption))
            .foregroundStyle(theme.foreground.darker(1.5).color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// TextField.qml under a field label: the control fill and border, hover and focus as hot.
struct OmarchyTextField: View {
    let label: String
    var description: String = ""
    @Binding var text: String
    let placeholder: String
    let theme: OmarchyTheme
    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        let hot = focused || hovering
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: label, theme: theme)
            // macOS draws a TextField prompt in its own placeholder grey whatever the style says,
            // which vanishes on light themes, so the placeholder is drawn underneath instead.
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(OmarchyStyle.font(OmarchyStyle.FontSize.body))
                .foregroundStyle(theme.foreground.color)
                .focused($focused)
                .background(alignment: .leading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(OmarchyStyle.font(OmarchyStyle.FontSize.body))
                            .foregroundStyle(theme.foreground.darker(1.6).color)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 10 + 1)
                .padding(.vertical, 7 + 1)
                .background(theme.foreground.color(opacity: hot ? 0.08 : 0.04))
                .overlay(Rectangle().strokeBorder(theme.foreground.color(opacity: hot ? 0.25 : 0.4), lineWidth: 1))
                .onHover { hovering = $0 }
            if !description.isEmpty { FieldDescription(text: description, theme: theme) }
        }
    }
}

/// NumberField.qml: a 120-unit spin box, value centred, stepping down and up at its ends.
struct OmarchyNumberField: View {
    let label: String
    let value: Int
    let range: ClosedRange<Int>
    let step: Int
    let theme: OmarchyTheme
    let onChange: (Int) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        let hot = focused || hovering
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: label, theme: theme)
            HStack(spacing: 0) {
                stepper("−") { onChange(max(range.lowerBound, value - step)) }
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(OmarchyStyle.font(OmarchyStyle.FontSize.body))
                    .foregroundStyle(theme.foreground.color)
                    .focused($focused)
                    .onSubmit(commit)
                stepper("+") { onChange(min(range.upperBound, value + step)) }
            }
            .frame(width: 120, height: 28)
            .background(theme.foreground.color(opacity: hot ? 0.08 : 0.04))
            .overlay(Rectangle().strokeBorder(theme.foreground.color(opacity: hot ? 0.25 : 0.4), lineWidth: 1))
            .onHover { hovering = $0 }
        }
        .onAppear { draft = String(value) }
        .onChange(of: value) { _, new in draft = String(new) }
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func stepper(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(symbol)
                .font(OmarchyStyle.font(OmarchyStyle.FontSize.body))
                .foregroundStyle(theme.foreground.color)
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func commit() {
        if let number = Int(draft.trimmingCharacters(in: .whitespaces)) {
            onChange(number)
        }
        draft = String(value)
    }
}

/// A folder under a field label: its path, a bordered Choose… button, and Reset when changed.
struct FolderField: View {
    let label: String
    var description: String = ""
    let path: String
    let placeholder: String
    let canReset: Bool
    let theme: OmarchyTheme
    let onChoose: () -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: label, theme: theme)
            HStack(spacing: 6) {
                Text(path.isEmpty ? placeholder : path)
                    .font(OmarchyStyle.font(OmarchyStyle.FontSize.caption))
                    .foregroundStyle((path.isEmpty ? theme.dim : theme.foreground).color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose…", action: onChoose).buttonStyle(OmarchyButtonStyle(theme: theme))
                if canReset {
                    Button("Reset", action: onReset).buttonStyle(OmarchyButtonStyle(theme: theme))
                }
            }
            if !description.isEmpty { FieldDescription(text: description, theme: theme) }
        }
    }
}

/// Button.qml with `bordered`: the normal border at rest, the hover fill and cursor border when hot.
struct OmarchyButtonStyle: ButtonStyle {
    let theme: OmarchyTheme

    func makeBody(configuration: Configuration) -> some View {
        ButtonBody(configuration: configuration, theme: theme)
    }

    private struct ButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let theme: OmarchyTheme
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(OmarchyStyle.font(OmarchyStyle.FontSize.bodySmall))
                .foregroundStyle(theme.foreground.color)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10 + 1)
                .padding(.vertical, 6 + 1)
                .background(theme.foreground.color(opacity: configuration.isPressed ? 0.22 : hovering ? 0.08 : 0))
                .overlay(Rectangle().strokeBorder(theme.foreground.color(opacity: hovering ? 0.25 : 0.4), lineWidth: 1))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
