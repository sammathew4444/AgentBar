import SwiftUI

/// Panel content. Until records exist this is agents/Panel.qml with no providers: the hero is hidden
/// and only the empty-state line shows. The rest of the layout arrives in Phase 4.
struct PanelView: View {
    let theme: OmarchyTheme

    var body: some View {
        PanelCard(theme: theme) {
            Text("No AI coding subscriptions found.\nAgents show up here once you've used them.")
                .font(OmarchyStyle.font(OmarchyStyle.FontSize.body))
                .foregroundStyle(theme.dim.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
        }
    }
}

/// KeyboardPanel's card (shell/Ui/KeyboardPanel.qml): a BorderSurface filled with the popup
/// background, its border drawn inside the bounds as Qt's Rectangle does, with padding inside that.
struct PanelCard<Content: View>: View {
    let theme: OmarchyTheme
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(OmarchyStyle.popupPadding + OmarchyStyle.popupBorderWidth)
            .frame(width: OmarchyStyle.panelWidth)
            .background(theme.popupBackground.color)
            .overlay(
                RoundedRectangle(cornerRadius: OmarchyStyle.cornerRadius)
                    .strokeBorder(theme.popupBorder.color, lineWidth: OmarchyStyle.popupBorderWidth)
            )
            .clipShape(RoundedRectangle(cornerRadius: OmarchyStyle.cornerRadius))
    }
}
