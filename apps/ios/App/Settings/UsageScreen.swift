import PalDesign
import PalProtocol
import PalSettings
import Observation
import SwiftUI

@MainActor
@Observable
final class UsageModel {
    private(set) var state: Loadable<UsageOverview> = .loading
    private(set) var refreshFailure: String?
    private(set) var isRefreshing = false

    private let surfaces: SurfaceCache

    init(surfaces: SurfaceCache) {
        self.surfaces = surfaces
    }

    static let surfaceKey = SurfaceKey.screen("usage")

    func load(api: SettingsAPI) async {
        if state.value == nil, let cached = await surfaces.value(UsageOverview.self, Self.surfaceKey), state.value == nil {
            state = .loaded(cached)
        }
        if state.value == nil { await read(api: api, refresh: false) }
        await refresh(api: api)
    }

    func refresh(api: SettingsAPI) async {
        isRefreshing = true
        defer { isRefreshing = false }
        await read(api: api, refresh: true)
    }

    private func read(api: SettingsAPI, refresh: Bool) async {
        do {
            let subscriptions = try await api.subscriptions(refresh: refresh)
            let overview = UsageOverview(subscriptions)
            state = .loaded(overview)
            refreshFailure = nil
            surfaces.persist(overview, Self.surfaceKey)
        } catch is CancellationError {
            return
        } catch {
            let message = SettingsFailure(error).message
            if state.value == nil { state = .failed(message) } else { refreshFailure = message }
        }
    }
}

struct UsageScreen: View {
    let hub: SettingsHub
    let back: () -> Void

    @State private var model: UsageModel
    @Environment(\.hermesTheme) private var theme

    init(hub: SettingsHub, back: @escaping () -> Void) {
        self.hub = hub
        self.back = back
        _model = State(initialValue: UsageModel(surfaces: hub.connection.surfaces))
    }

    var body: some View {
        SettingsPage(title: "Usage", identifier: "usageScreen", back: back) {
            switch model.state {
            case .loading:
                GroupedCard(accessibilityIdentifier: "usageLoading") {
                    LoadingRow(title: "Usage", identifier: "usageLoadingRow")
                }
            case .failed(let message):
                FailureCard(message: message, identifier: "usageFailure") { Task { await model.refresh(api: hub.api) } }
            case .loaded(let overview):
                if overview.accounts.isEmpty {
                    GroupedCard(accessibilityIdentifier: "usageEmpty") {
                        PlaceholderRow("No accounts connected yet", accessibilityIdentifier: "usageEmptyRow")
                    }
                } else {
                    ForEach(overview.accounts) { account in
                        UsageAccountSection(account: account)
                    }
                }
                if let failure = model.refreshFailure {
                    CardFootnote(failure, accessibilityIdentifier: "usageRefreshFailure")
                }
            }
        }
        .refreshable { await model.refresh(api: hub.api) }
        .task { await model.load(api: hub.api) }
    }
}

struct UsageAccountSection: View {
    let account: UsageAccount

    var body: some View {
        TimelineView(.everyMinute) { timeline in
            VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
                SectionCaption(caption, accessibilityIdentifier: "usageCaption-\(account.id)")
                GroupedCard(accessibilityIdentifier: "usageCard-\(account.id)") {
                    ForEach(account.meters) { meter in
                        UsageGaugeRow(
                            title: meter.title, caption: meter.resetText(now: timeline.date), fraction: meter.fraction,
                            valueText: meter.percentText, accessibilityIdentifier: "usageMeter-\(meter.id)"
                        )
                    }
                    if account.hasNoLimits {
                        SettingsRow(
                            title: "No usage limits", subtitle: "This account is billed by usage.",
                            accessibilityIdentifier: "usageNoLimits-\(account.id)"
                        )
                    }
                    if let spend = account.spend {
                        SettingsRow(
                            title: spend.title, subtitle: spend.detailText, value: spend.valueText(),
                            accessibilityIdentifier: "usageSpend-\(account.id)"
                        )
                    }
                    if let note = account.note {
                        SettingsRow(title: note, accessibilityIdentifier: "usageNote-\(account.id)")
                    }
                    if account.meters.isEmpty, account.spend == nil, account.note == nil, !account.hasNoLimits {
                        SettingsRow(title: "Usage is not available yet.", accessibilityIdentifier: "usageNone-\(account.id)")
                    }
                }
            }
        }
    }

    private var caption: String {
        var parts = [account.title]
        if let label = account.accountLabel { parts.append(label) }
        if account.standing == .limited { parts.append("Limit reached") }
        return parts.joined(separator: " · ")
    }
}
