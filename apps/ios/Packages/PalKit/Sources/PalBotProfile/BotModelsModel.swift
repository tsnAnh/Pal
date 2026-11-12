import Foundation
import Observation

@MainActor
@Observable
public final class BotModelsModel {
    public enum Phase: Sendable, Equatable {
        case loading
        case ready
        case failed
    }

    public enum Save: Sendable, Equatable {
        case idle
        case saving
        case saved(String)
        case failed(String)
    }

    public struct Confirmation: Sendable, Equatable {
        public let choice: ModelChoice
        public let message: String
    }

    public private(set) var phase = Phase.loading
    public private(set) var settings = BotModelSettings(current: nil, fallbacks: [])
    public private(set) var providers: [ModelCatalogProvider] = []
    public private(set) var effort: String?
    public private(set) var save = Save.idle
    public var confirmation: Confirmation?

    @ObservationIgnored private let client: BotModelClient

    public init(client: BotModelClient) {
        self.client = client
    }

    public var isSaving: Bool { save == .saving }

    public var currentText: String? {
        settings.current.map { displayName(for: $0) }
    }

    public var usableProviders: [ModelCatalogProvider] { providers.filter { $0.hasCredential && !$0.models.isEmpty } }

    public var providersNeedingKey: [ModelCatalogProvider] { providers.filter { !$0.hasCredential } }

    public var effortOptions: EffortOptions {
        guard let current = settings.current else { return .unknown }
        let capability = providers.first { $0.id == current.provider }?.capabilities[current.model]
        return ReasoningEffort.options(for: capability)
    }

    public func displayName(for choice: ModelChoice) -> String {
        choice.model
    }

    public func providerName(for choice: ModelChoice) -> String {
        providers.first { $0.id == choice.provider }?.name ?? choice.provider
    }

    public func models(matching query: String) -> [ModelCatalogProvider] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return usableProviders }
        return usableProviders.compactMap { provider in
            if provider.name.lowercased().contains(needle) { return provider }
            let hits = provider.models.filter { $0.lowercased().contains(needle) }
            return hits.isEmpty ? nil : ModelCatalogProvider(id: provider.id, name: provider.name, models: hits)
        }
    }

    public func load() async {
        if phase == .failed { phase = .loading }
        async let loadedSettings = try? client.settings()
        async let loadedCatalog = try? client.catalog()
        async let loadedEffort = try? client.effort()
        let (fresh, catalog, reportedEffort) = await (loadedSettings, loadedCatalog, loadedEffort)
        if let catalog { providers = catalog }
        if !isSaving { effort = reportedEffort }
        guard let fresh else {
            if phase == .loading { phase = .failed }
            return
        }
        if !isSaving { settings = fresh }
        phase = .ready
    }

    public func choose(_ choice: ModelChoice) async {
        guard !isSaving, choice != settings.current else { return }
        await commit(choice, confirmed: false)
    }

    public func confirmPending() async {
        guard let pending = confirmation else { return }
        confirmation = nil
        guard !isSaving else { return }
        await commit(pending.choice, confirmed: true)
    }

    private func commit(_ choice: ModelChoice, confirmed: Bool) async {
        save = .saving
        switch await client.setModel(choice, confirmed: confirmed) {
        case .saved:
            settings.current = choice
            save = .saved("Saved. New turns use this model; a turn already running finishes on its current one.")
        case .needsConfirmation(let message):
            confirmation = Confirmation(choice: choice, message: message)
            save = .idle
        case .failed(let reason):
            save = .failed(reason)
        }
    }

    public func chooseEffort(_ level: String) async {
        guard !isSaving, level != effort else { return }
        save = .saving
        switch await client.setEffort(level) {
        case .saved:
            effort = level
            save = .saved("Saved. New conversations use this effort; ones already open keep theirs.")
        case .failed(let reason):
            save = .failed(reason)
        case .needsConfirmation:
            save = .failed(BotModelClient.couldNotSaveEffort)
        }
    }

    public func addFallback(_ choice: ModelChoice) async {
        guard !settings.fallbacks.contains(choice), choice != settings.current else { return }
        await commitFallbacks(settings.fallbacks + [choice])
    }

    public func removeFallback(_ choice: ModelChoice) async {
        await commitFallbacks(settings.fallbacks.filter { $0 != choice })
    }

    public func moveFallback(_ choice: ModelChoice, by offset: Int) async {
        var next = settings.fallbacks
        guard let index = next.firstIndex(of: choice) else { return }
        let target = index + offset
        guard next.indices.contains(target) else { return }
        next.swapAt(index, target)
        await commitFallbacks(next)
    }

    private func commitFallbacks(_ next: [ModelChoice]) async {
        guard !isSaving else { return }
        save = .saving
        switch await client.setFallbacks(next) {
        case .saved:
            settings.fallbacks = next
            save = .saved("Saved. Backups apply from the next turn.")
        case .failed(let reason):
            save = .failed(reason)
        case .needsConfirmation:
            save = .failed(BotModelClient.couldNotSaveFallbacks)
        }
    }
}
