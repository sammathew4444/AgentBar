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
    /// The records on this machine, before the enabled filter and the sync merge.
    private(set) var localRecords: [UsageRecord] = []
    private(set) var disabledAgents: Set<String> = []
    private(set) var syncAggregate: UsageSync.Aggregate?
    private(set) var syncStatusText = ""
    /// Devices behind each merged provider (`syncDeviceCount`).
    private(set) var syncDeviceCounts: [String: Int] = [:]
    /// The keyboard cursor is on the provider switch.
    var cursorActive = false
    /// Countdowns read this instead of the clock so an open panel keeps telling the truth.
    var now = Date()
    /// The tallest the content may be: what the screen has room for. The panel only scrolls
    /// past this, never at Omarchy's fixed 640 cap.
    var maxContentHeight: CGFloat = .infinity
    /// The gear flips the panel to its settings page.
    var showingSettings = false

    /// Called after anything the bar icon depends on changes.
    @ObservationIgnored var onChange: (() -> Void)?

    var providerIndex: Int {
        providers.firstIndex { $0.id == selectedProviderID } ?? 0
    }

    var provider: UsageRecord? {
        providers.isEmpty ? nil : providers[providerIndex]
    }

    var alarming: Bool { PanelLogic.alarming(provider) }

    /// `footerText`: only speaks up when the numbers cover more than this machine.
    var footerText: String {
        if !syncStatusText.isEmpty { return syncStatusText }
        guard let provider, let devices = syncDeviceCounts[provider.id], devices > 0 else { return "" }
        return "Merged from \(devices) device" + (devices == 1 ? "" : "s")
    }

    func update(records: [UsageRecord]) {
        localRecords = records
        rebuild()
    }

    func setDisabledAgents(_ ids: Set<String>) {
        disabledAgents = ids
        rebuild()
    }

    func setSync(_ aggregate: UsageSync.Aggregate?, status: String) {
        syncAggregate = aggregate
        syncStatusText = status
        rebuild()
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

    /// `enabledProviders`: enabled agents with numbers, merged with synced stats when there are
    /// any, then agents that only ran on other machines.
    private func rebuild() {
        var next: [UsageRecord] = []
        var counts: [String: Int] = [:]
        var local: Set<String> = []
        for record in localRecords {
            local.insert(record.id)
            guard !disabledAgents.contains(record.id) else { continue }
            var display = record
            if let aggregate = syncAggregate, let stats = aggregate.providers[record.id] {
                display = UsageSync.merged(record, with: stats)
                counts[record.id] = stats.deviceCount ?? aggregate.deviceCount
            }
            if PanelLogic.providerHasData(display) { next.append(display) }
        }
        if let aggregate = syncAggregate {
            for id in aggregate.providers.keys.sorted() where !local.contains(id) && !disabledAgents.contains(id) {
                let stats = aggregate.providers[id]!
                // Rate limits are per account and never travel, so these show stats only.
                let display = UsageSync.merged(UsageRecord(id: id, name: stats.providerName.isEmpty ? id : stats.providerName), with: stats)
                counts[id] = stats.deviceCount ?? aggregate.deviceCount
                if PanelLogic.providerHasData(display) { next.append(display) }
            }
        }
        if next != providers { providers = next }
        if counts != syncDeviceCounts { syncDeviceCounts = counts }
        onChange?()
    }
}
