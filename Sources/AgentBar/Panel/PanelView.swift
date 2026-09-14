import AppKit
import SwiftUI

/// The agents panel (shell/plugins/agents/Panel.qml): hero, provider switch, status, balance,
/// limits, tokens by day, tokens by model. Sizes are Style.qml tokens at their defaults.
struct PanelView: View {
    let model: PanelModel
    let themeStore: ThemeStore
    let settings: AppSettings
    /// Off only for rendering the full content to an image, which can't draw a scroll view.
    var scrollable = true
    /// Folder choosers need an open panel, which the controller owns.
    var onChooseFolder: (FolderPurpose) -> Void = { _ in }

    /// The card's padding and border, top and bottom.
    static let verticalInsets: CGFloat = 2 * (OmarchyStyle.popupPadding + OmarchyStyle.popupBorderWidth)

    var body: some View {
        let theme = themeStore.current
        PanelCard(theme: theme) {
            if scrollable && model.showingSettings {
                // Only the settings page scrolls, and only once it outgrows the height cap.
                ViewThatFits(in: .vertical) {
                    content(theme)
                    ScrollView(.vertical) { content(theme) }
                }
                .frame(maxHeight: model.maxContentHeight)
            } else if scrollable {
                // Omarchy caps the panel at Style.space(640) and scrolls past it; the usage page
                // here never scrolls. It grows with its content, up to the same cap.
                content(theme)
                    .frame(maxHeight: model.maxContentHeight, alignment: .top)
                    .clipped()
            } else {
                content(theme)
            }
        }
        .overlayPreferenceValue(ThemeButtonAnchor.self) { anchor in
            if themeStore.pickerOpen, let anchor {
                GeometryReader { geometry in
                    let button = geometry[anchor]
                    ZStack(alignment: .topLeading) {
                        // A click anywhere else in the panel closes the list, as a Popup does.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { themeStore.closePicker() }
                        ThemePickerList(store: themeStore, theme: theme, scrollable: scrollable, onChoose: choose)
                            .offset(x: button.maxX - ThemePickerList.outerWidth, y: button.maxY + 2)
                    }
                }
            }
        }
    }

    private func choose(_ option: ThemeStore.Option) {
        if themeStore.choose(option) { onChooseFolder(.theme) }
    }

    /// The hero on top, then either the usage or the settings page.
    private func content(_ theme: OmarchyTheme) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let provider = model.provider {
                HeroView(record: provider, theme: theme, themeStore: themeStore, settingsActive: model.showingSettings, onSettings: toggleSettings)
            } else {
                // Only seen once agents are switched off here: the way back to settings stays.
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HeroButtons(themeStore: themeStore, theme: theme, settingsActive: model.showingSettings, onSettings: toggleSettings)
                }
            }
            if model.showingSettings {
                SettingsView(settings: settings, theme: theme, onChooseFolder: onChooseFolder)
            } else {
                usageContent(theme)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleSettings() {
        themeStore.closePicker()
        model.showingSettings.toggle()
    }

    private func usageContent(_ theme: OmarchyTheme) -> some View {
        let provider = model.provider
        let limits = PanelLogic.limitWindows(provider)
        let models = PanelLogic.modelRows(provider)
        let days = provider?.recentDays ?? []

        return VStack(alignment: .leading, spacing: 12) {
            if provider == nil {
                Text("No AI coding subscriptions found.\nAgents show up here once you've used them.")
                    .font(OmarchyStyle.font(OmarchyStyle.FontSize.body))
                    .foregroundStyle(theme.dim.color)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
            }

            if model.providers.count > 1 {
                ProviderSwitch(model: model, theme: theme)
            }

            if let provider, !provider.usageStatusText.isEmpty {
                StatusCard(text: provider.authHelpText, theme: theme)
            }

            if provider?.balance != nil || !limits.isEmpty {
                PanelSeparator(theme: theme)
            }
            if let balance = provider?.balance {
                BalanceSection(balance: balance, theme: theme)
            }
            if !limits.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(text: "LIMITS", theme: theme)
                    ForEach(Array(limits.enumerated()), id: \.offset) { _, window in
                        LimitRow(window: window, now: model.now, theme: theme)
                    }
                }
            }

            if !days.isEmpty {
                PanelSeparator(theme: theme)
                let peak = Double(max(1, PanelLogic.weekPeak(provider)))
                let today = PanelLogic.todayDate(now: model.now)
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(text: "TOKENS BY DAY", theme: theme)
                    ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                        // By date, not by position: a fallback window can stop short of today.
                        let isToday = day.date == today
                        DayRow(
                            day: day, ratio: Double(day.messageCount) / peak, today: isToday,
                            tooltip: PanelLogic.dayTooltip(day, today: isToday, record: provider), theme: theme
                        )
                    }
                }
            }

            if !models.isEmpty {
                PanelSeparator(theme: theme)
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(text: "TOKENS BY MODEL", theme: theme)
                    ForEach(Array(models.enumerated()), id: \.offset) { _, row in
                        // Scaled to the heaviest model, the same way the week scales to its busiest day.
                        ModelRowView(row: row, share: Double(row.total) / Double(max(1, models[0].total)), theme: theme)
                    }
                }
            }

            // `footerText`: only when the numbers cover more than this machine, or sync failed.
            let footer = model.footerText
            if !footer.isEmpty {
                Text(footer)
                    .font(OmarchyStyle.font(OmarchyStyle.FontSize.caption))
                    .foregroundStyle(theme.dim.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Chrome

/// KeyboardPanel's card: a BorderSurface filled with the popup background, its border drawn
/// inside the bounds (solid, or the theme's gradient), with padding inside that.
struct PanelCard<Content: View>: View {
    let theme: OmarchyTheme
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(OmarchyStyle.popupPadding + OmarchyStyle.popupBorderWidth)
            .frame(width: OmarchyStyle.panelWidth)
            .background(theme.popupBackground.color)
            .overlay(BorderRing(paint: theme.popupBorder, width: OmarchyStyle.popupBorderWidth))
    }
}

/// PanelSeparator: a 1px rule, foreground at 12%.
struct PanelSeparator: View {
    let theme: OmarchyTheme

    var body: some View {
        Rectangle().fill(theme.foreground.color(opacity: 0.12)).frame(height: 1)
    }
}

/// PanelSectionHeader: caption, bold, darkened foreground, with room for glyph overshoot on top.
struct SectionHeader: View {
    let text: String
    let theme: OmarchyTheme

    var body: some View {
        Text(text)
            .font(OmarchyStyle.font(OmarchyStyle.FontSize.caption, bold: true))
            .foregroundStyle(theme.headerDim.color)
            .padding(.top, (OmarchyStyle.FontSize.caption * 0.15).rounded(.up))
    }
}

// MARK: - Hero

/// PanelHero: the provider's mark, its name, and the plan (or the status) in small caps, with
/// the theme button in the hero's `trailingControl` slot, centred against the labels.
struct HeroView: View {
    let record: UsageRecord
    let theme: OmarchyTheme
    let themeStore: ThemeStore
    let settingsActive: Bool
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 14) {
                ProviderMark(id: record.id, theme: theme)
                    .frame(width: OmarchyStyle.FontSize.display, height: OmarchyStyle.FontSize.display)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.name)
                        .font(OmarchyStyle.font(OmarchyStyle.FontSize.title, bold: true))
                        .foregroundStyle(theme.foreground.color)
                        .lineLimit(1)
                    let meta = PanelLogic.heroMeta(record).uppercased()
                    if !meta.isEmpty {
                        Text(meta)
                            .font(OmarchyStyle.font(OmarchyStyle.FontSize.caption, bold: true))
                            .kerning(1.2)
                            .foregroundStyle(theme.headerDim.color)
                            .lineLimit(1)
                    }
                }
            }
            // PanelHero reserves the control's width plus Style.space(12).
            Spacer(minLength: 12)
            HeroButtons(themeStore: themeStore, theme: theme, settingsActive: settingsActive, onSettings: onSettings)
        }
    }
}

/// The hero's trailing controls: the theme list and the settings page.
struct HeroButtons: View {
    /// Nerd Fonts `md-cog`.
    static let gear = "\u{F0493}"

    let themeStore: ThemeStore
    let theme: OmarchyTheme
    let settingsActive: Bool
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ThemeButton(store: themeStore, theme: theme)
            Button(action: onSettings) {
                GlyphIcon(glyph: Self.gear)
            }
            .buttonStyle(IconButtonStyle(active: settingsActive, theme: theme))
            .accessibilityLabel("Settings")
        }
    }
}

/// A Nerd Font icon at `Style.font.icon` in a 16-unit square (`Style.bar.iconCanvas`), centred
/// by its outline as OpticalGlyph does, and tinted by the surrounding foreground style.
struct GlyphIcon: View {
    let glyph: String
    var fontSize: CGFloat = OmarchyStyle.FontSize.icon
    var canvas: CGFloat = BarGlyph.canvas

    var body: some View {
        if let image = BarGlyph.centredImage(glyph, fontSize: fontSize, canvas: canvas, color: nil) {
            Image(nsImage: image).renderingMode(.template)
        } else {
            Text(glyph).font(OmarchyStyle.font(fontSize)).fixedSize()
        }
    }
}

/// `assets/<id>.svg` (with an `-light` twin tried first on light surfaces), else the bar glyph.
struct ProviderMark: View {
    let id: String
    let theme: OmarchyTheme

    var body: some View {
        if let image = Self.image(for: id, lightSurface: theme.popupBackground.luminance >= 0.5) {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else {
            GlyphIcon(glyph: BarGlyph.robotGlyph, fontSize: OmarchyStyle.FontSize.display, canvas: OmarchyStyle.FontSize.display)
                .foregroundStyle(theme.foreground.color)
        }
    }

    static func image(for id: String, lightSurface: Bool, size: CGFloat = OmarchyStyle.FontSize.display) -> NSImage? {
        let names = (lightSurface ? [id + "-light"] : []) + [id]
        for name in names {
            if let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "Agents"),
               let data = try? Data(contentsOf: url),
               let image = NSImage(data: SVGCompat.normalized(data)) {
                return fitted(image, to: size)
            }
        }
        return nil
    }

    /// Gives a vector mark its display size before SwiftUI rasterises it. Some marks declare
    /// `width="1em"`, which NSImage reads as 1 × 1 pt and SwiftUI would blow up into a blur.
    static func fitted(_ image: NSImage, to side: CGFloat) -> NSImage {
        let natural = image.size
        let aspect = natural.width > 1 && natural.height > 1 ? natural.width / natural.height : 1
        image.size = aspect >= 1
            ? NSSize(width: side, height: side / aspect)
            : NSSize(width: side * aspect, height: side)
        return image
    }
}

// MARK: - Theme button and list

/// Where the theme button sits, so the list can open beneath it.
private struct ThemeButtonAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// A borderless icon Button (shell/Ui/Button.qml) with `md-palette`, shown as hot while its
/// list is open, as Dropdown's trigger is while focused.
struct ThemeButton: View {
    /// Nerd Fonts `md-palette`.
    static let glyph = "\u{F03D8}"

    let store: ThemeStore
    let theme: OmarchyTheme

    var body: some View {
        Button {
            store.togglePicker()
        } label: {
            GlyphIcon(glyph: Self.glyph)
        }
        .buttonStyle(IconButtonStyle(active: store.pickerOpen, theme: theme))
        .anchorPreference(key: ThemeButtonAnchor.self, value: .bounds) { $0 }
        .accessibilityLabel("Theme")
    }
}

/// Button.qml without `bordered`: nothing at rest, the hover fill and cursor border when hot,
/// the pressed fill while held. The border's space is always reserved, so nothing shifts.
struct IconButtonStyle: ButtonStyle {
    let active: Bool
    let theme: OmarchyTheme

    func makeBody(configuration: Configuration) -> some View {
        IconBody(configuration: configuration, active: active, theme: theme)
    }

    private struct IconBody: View {
        let configuration: ButtonStyleConfiguration
        let active: Bool
        let theme: OmarchyTheme
        @State private var hovering = false

        var body: some View {
            let hot = hovering || active
            configuration.label
                .foregroundStyle(theme.foreground.color)
                .padding(.horizontal, 10 + 1)
                .padding(.vertical, 6 + 1)
                .background(theme.foreground.color(opacity: configuration.isPressed ? 0.22 : hot ? 0.08 : 0))
                .overlay(Rectangle().strokeBorder(theme.foreground.color(opacity: hot ? 0.25 : 0), lineWidth: 1))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// Dropdown.qml's popup: the popup surface with a 1px popup border, 28-unit rows 4 apart, the
/// highlighted row in the hover fill, at most eight rows before it scrolls.
struct ThemePickerList: View {
    static let rowHeight: CGFloat = 28
    static let rowGap: CGFloat = 4
    /// `Style.spacing.dropdownWidth`.
    static let width: CGFloat = 240
    /// Border plus `Style.spacing.hairline`, each side.
    static let inset: CGFloat = 1 + 1
    static var outerWidth: CGFloat { width + inset * 2 }

    let store: ThemeStore
    let theme: OmarchyTheme
    /// Off only for rendering to an image: every row in a plain stack instead of a scroll view.
    var scrollable = true
    let onChoose: (ThemeStore.Option) -> Void

    var body: some View {
        let options = store.options
        let visible = CGFloat(min(options.count, 8))
        Group {
            if scrollable {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        rows(options)
                    }
                    .frame(width: Self.width, height: visible * Self.rowHeight + max(0, visible - 1) * Self.rowGap)
                    .onAppear { proxy.scrollTo(store.pickerIndex, anchor: .center) }
                    .onChange(of: store.pickerIndex) { _, index in proxy.scrollTo(index) }
                }
            } else {
                rows(options).frame(width: Self.width)
            }
        }
        .padding(Self.inset)
        .background(theme.popupBackground.color)
        .overlay(BorderRing(paint: theme.popupBorder, width: 1))
    }

    private func rows(_ options: [ThemeStore.Option]) -> some View {
        VStack(spacing: Self.rowGap) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                Text(option.title)
                    .font(OmarchyStyle.font(OmarchyStyle.FontSize.body))
                    .foregroundStyle(theme.foreground.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: Self.rowHeight)
                    .background(index == store.pickerIndex ? theme.foreground.color(opacity: 0.08) : .clear)
                    .contentShape(Rectangle())
                    .onHover { if $0 { store.pickerIndex = index } }
                    .onTapGesture { onChoose(option) }
                    .id(index)
            }
        }
    }
}

// MARK: - Provider switch

/// One chip per agent, sharing the row equally (Button with `bordered` and `selected`).
struct ProviderSwitch: View {
    let model: PanelModel
    let theme: OmarchyTheme

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(model.providers.enumerated()), id: \.element.id) { index, provider in
                Button(provider.name) {
                    model.cursorActive = true
                    model.select(index)
                }
                .buttonStyle(ChipStyle(
                    selected: index == model.providerIndex,
                    hasCursor: model.cursorActive && index == model.providerIndex,
                    theme: theme
                ))
                .onHover { if $0 { model.cursorActive = true } }
            }
        }
    }
}

/// Button.qml's fills and borders, the [controls] defaults from shell.toml.tpl. One change to its
/// paint order: there hover or the keyboard cursor beats selected, so the active chip drops to the
/// 8% hover fill as soon as the pointer has been over the row and barely stands out. Here the
/// active chip keeps the 18% selected fill and its normal border; hover lightens only the others.
struct ChipStyle: ButtonStyle {
    let selected: Bool
    let hasCursor: Bool
    let theme: OmarchyTheme

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, selected: selected, hasCursor: hasCursor, theme: theme)
    }

    private struct ChipBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        let hasCursor: Bool
        let theme: OmarchyTheme
        @State private var hovering = false

        var body: some View {
            let hot = hovering || hasCursor
            let fill: Double = configuration.isPressed ? 0.22 : selected ? 0.18 : hot ? 0.08 : 0
            // An inactive chip under the cursor takes the cursor border; otherwise a bordered
            // button keeps its normal border, selected included, since selected-border-width is 0.
            let borderAlpha = hot && !selected ? 0.25 : 0.4

            configuration.label
                .font(OmarchyStyle.font(OmarchyStyle.FontSize.bodySmall, bold: selected))
                .foregroundStyle(theme.foreground.color)
                .lineLimit(1)
                .padding(.horizontal, 10 + 1)
                .padding(.vertical, 6 + 1)
                .frame(maxWidth: .infinity)
                .background(theme.foreground.color(opacity: fill))
                .overlay(Rectangle().strokeBorder(theme.foreground.color(opacity: borderAlpha), lineWidth: 1))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Status

/// Auth and endpoint problems: the help text on an urgent-tinted card.
struct StatusCard: View {
    let text: String
    let theme: OmarchyTheme

    var body: some View {
        Text(text)
            .font(OmarchyStyle.font(OmarchyStyle.FontSize.caption))
            .foregroundStyle(theme.dim.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(theme.urgent.color(opacity: 0.10))
            .overlay(Rectangle().strokeBorder(theme.urgent.color(opacity: 0.35), lineWidth: 1))
    }
}

// MARK: - Balance and limits

struct BalanceSection: View {
    let balance: UsageRecord.Balance
    let theme: OmarchyTheme

    var body: some View {
        let alarming = PanelLogic.balanceAlarming(balance)
        let ratio = PanelLogic.balanceRatio(balance)
        let detail = PanelLogic.balanceDetailText(balance)

        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: "BALANCE", theme: theme)
            HStack {
                Text("Prepaid credits")
                    .font(OmarchyStyle.font(OmarchyStyle.FontSize.body))
                    .foregroundStyle(theme.foreground.color)
                Spacer(minLength: 0)
                Text(PanelLogic.formatMoney(balance.remaining, currency: balance.currency))
                    .font(OmarchyStyle.font(OmarchyStyle.FontSize.caption))
                    .foregroundStyle((alarming ? theme.urgent : theme.foreground).color)
            }
            if ratio >= 0 {
                Meter(value: ratio, alarming: alarming, theme: theme)
            }
            if !detail.isEmpty {
                Text(detail)
                    .font(OmarchyStyle.font(OmarchyStyle.FontSize.caption))
                    .foregroundStyle(theme.dim.color)
            }
        }
    }
}

/// A limit window: title and percentage, meter, and reset countdown.
struct LimitRow: View {
    let window: PanelLogic.Window
    let now: Date
    let theme: OmarchyTheme

    var body: some View {
        let alarming = window.percent >= 0.9
        let reset = PanelLogic.resetText(window, now: now)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                // Model-scoped titles run long, so the title gives way before the percentage.
                Text(window.title)
                    .font(OmarchyStyle.font(OmarchyStyle.FontSize.body))
                    .foregroundStyle(theme.foreground.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(PanelLogic.percentText(window))
                    .font(OmarchyStyle.font(OmarchyStyle.FontSize.caption))
                    .foregroundStyle((alarming ? theme.urgent : theme.foreground).color)
            }
            Meter(value: window.percent, alarming: alarming, theme: theme)
            // An empty Qt Text still holds its line, so the row keeps its height without a reset.
            Text(reset.isEmpty ? " " : reset)
                .font(OmarchyStyle.font(OmarchyStyle.FontSize.caption))
                .foregroundStyle(theme.dim.color)
        }
    }
}

/// A rounded track, filled to the share of the allowance used (or the credit left).
/// Static: Omarchy animates the fill width, but switching agents here redraws in place.
struct Meter: View {
    let value: Double
    let alarming: Bool
    let theme: OmarchyTheme

    /// `max(Style.space(4), round(controlHeight * 0.14))`.
    static let thickness: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // `Style.selectedFillFor(foreground)`: foreground at the selected-fill alpha.
                Capsule().fill(theme.foreground.color(opacity: 0.18))
                Capsule()
                    .fill((alarming ? theme.urgent : theme.foreground).color)
                    .frame(width: geometry.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: Self.thickness)
    }
}

// MARK: - Days and models

/// Label, bar, tokens. Today is picked out in full foreground.
struct DayRow: View {
    let day: UsageRecord.RecentDay
    let ratio: Double
    let today: Bool
    let tooltip: String
    let theme: OmarchyTheme

    var body: some View {
        let color = (today ? theme.foreground : theme.dim).color
        HStack(spacing: 0) {
            Text(PanelLogic.dayLabel(day.date, today: today))
                .font(OmarchyStyle.font(OmarchyStyle.FontSize.caption, bold: today))
                .foregroundStyle(color)
                .frame(width: 52, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.foreground.color(opacity: 0.18))
                    Capsule()
                        .fill(today ? theme.foreground.color : theme.foreground.color(opacity: 0.55))
                        .frame(width: geometry.size.width * min(1, max(0, ratio)))
                }
            }
            .frame(height: Meter.thickness)
            .padding(.leading, 8)
            .padding(.trailing, 10)
            Text(PanelLogic.formatTokenCount(day.messageCount))
                .font(OmarchyStyle.font(OmarchyStyle.FontSize.caption, bold: true))
                .foregroundStyle(color)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .panelToolTip(tooltip, theme: theme)
    }
}

/// A table row with its share bar filling the row behind the label.
struct ModelRowView: View {
    let row: PanelLogic.ModelRow
    let share: Double
    let theme: OmarchyTheme

    var body: some View {
        HStack(spacing: 8) {
            Text(row.name)
                .font(OmarchyStyle.font(OmarchyStyle.FontSize.bodySmall))
                .foregroundStyle(theme.foreground.color)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Text(PanelLogic.formatTokenCount(row.total))
                .font(OmarchyStyle.font(OmarchyStyle.FontSize.bodySmall, bold: true))
                .foregroundStyle(theme.dim.color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(alignment: .leading) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(theme.foreground.color(opacity: 0.05))
                    Rectangle()
                        .fill(theme.foreground.color(opacity: 0.14))
                        .frame(width: geometry.size.width * min(1, max(0, share)))
                }
            }
        }
        .panelToolTip(PanelLogic.modelTooltip(row), theme: theme)
    }
}

// MARK: - Tooltip

/// PanelToolTip: after a 400 ms hover, the text on the tooltip surface, centred just above the row.
private struct PanelToolTip: ViewModifier {
    let text: String
    let theme: OmarchyTheme
    @State private var visible = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { inside in
                pending?.cancel()
                visible = false
                guard inside else { return }
                pending = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    if !Task.isCancelled { visible = true }
                }
            }
            .overlay(alignment: .top) {
                if visible, !text.isEmpty {
                    Text(text)
                        .font(OmarchyStyle.font(OmarchyStyle.FontSize.bodySmall))
                        .foregroundStyle(theme.foreground.color)
                        .padding(.horizontal, 10 + 1)
                        .padding(.vertical, 6 + 1)
                        .background(theme.background.color(opacity: 0.97))
                        .overlay(BorderRing(paint: theme.tooltipBorder, width: 1))
                        .fixedSize()
                        .alignmentGuide(.top) { $0[.bottom] + 3 }
                        .allowsHitTesting(false)
                }
            }
            .zIndex(visible ? 1 : 0)
    }
}

private extension View {
    func panelToolTip(_ text: String, theme: OmarchyTheme) -> some View {
        modifier(PanelToolTip(text: text, theme: theme))
    }
}
