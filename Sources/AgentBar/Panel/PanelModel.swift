import Foundation
import Observation

/// What the panel and the bar icon show: the agents with data, and which one is selected.
/// The selection follows the provider, not its slot, so a provider whose first scan lands while
/// the panel is open doesn't swap out what you were reading (agents/Panel.qml).
@MainActor
@Observable
final class PanelModel {
    private(set) var providers: [UsageRecord] = []
    private(set) var selectedProviderID = ""
    /// The keyboard cursor is on the provider switch.
    var cursorActive = false
    /// Countdowns read this instead of the clock so an open panel keeps telling the truth.
    var now = Date()
    /// The tallest the content may be: what the screen has room for. The panel only scrolls
    /// past this, never at Omarchy's fixed 640 cap.
    var maxContentHeight: CGFloat = .infinity

    /// Called after anything the bar icon depends on changes.
    @ObservationIgnored var onChange: (() -> Void)?

    var providerIndex: Int {
        providers.firstIndex { $0.id == selectedProviderID } ?? 0
    }

    var provider: UsageRecord? {
        providers.isEmpty ? nil : providers[providerIndex]
    }

    var alarming: Bool { PanelLogic.alarming(provider) }

    func update(records: [UsageRecord]) {
        let next = records.filter(PanelLogic.providerHasData)
        guard next != providers else { return }
        providers = next
        onChange?()
    }

    func select(_ index: Int) {
        guard !providers.isEmpty else { return }
        let count = providers.count
        let wrapped = ((index % count) + count) % count
        selectedProviderID = providers[wrapped].id
        onChange?()
    }

    func cycle(by step: Int) {
        select(providerIndex + step)
    }
}
