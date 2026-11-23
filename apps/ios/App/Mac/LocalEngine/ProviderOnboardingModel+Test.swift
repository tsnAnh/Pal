#if os(macOS)
import Foundation
import PalBotProfile

extension ProviderOnboardingModel {
    static let collapsedModelCount = 5

    var canTest: Bool { selectedModel != nil && flow.canTest }

    var modelsAreEditable: Bool {
        switch flow.state {
        case .testing, .slow, .signingIn, .idle: false
        case .awaitingTest, .passed, .failed, .offline, .modelChanged: true
        }
    }

    var offeredModels: [String] {
        if case .loaded(let names) = catalog { names } else { [] }
    }

    var visibleModels: [String] {
        Self.collapse(offeredModels, selected: selectedModel, showsAll: showsAllModels)
    }

    var hiddenModelCount: Int { max(0, offeredModels.count - visibleModels.count) }

    static func collapse(_ models: [String], selected: String?, showsAll: Bool) -> [String] {
        guard !showsAll, models.count > collapsedModelCount else { return models }
        var shown = Array(models.prefix(collapsedModelCount))
        if let selected, models.contains(selected), !shown.contains(selected) { shown.append(selected) }
        return shown
    }

    func loadCatalog(for providerID: String) {
        catalogTask?.cancel()
        catalog = .loading
        let models = models
        catalogTask = Task { [weak self] in
            let all = try? await models.catalog()
            guard !Task.isCancelled, let self, case .test(let current) = self.screen, current == providerID else { return }
            let match = all?.first { $0.id == providerID }
            let names = match?.models ?? []
            catalog = names.isEmpty ? .unavailable : .loaded(names)
            if let first = match?.defaultModel, selectedModel == nil { pick(model: first) }
        }
    }

    func pick(model: String) {
        guard modelsAreEditable else { return }
        selectedModel = model
        flow.select(model: model)
    }

    func setManualModel(_ text: String) {
        manualModel = text
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            selectedModel = nil
        } else {
            pick(model: name)
        }
    }

    func runTest() async {
        guard canTest else { return }
        await flow.test()
    }

    func cancelTest() {
        flow.cancelTest()
    }

    func saveAndContinue() async {
        guard flow.canSaveAndContinue, !isFinishing else { return }
        guard await flow.saveAndContinue() else { return }
        await finish()
    }

    func removeProvider() async {
        guard await flow.remove() else { return }
        await providers.refresh()
        connectedHere = nil
        resetToChoice()
    }

    func signInAgain() async {
        guard let provider = flow.provider else { return }
        if provider.kind == .apiKey {
            changeKey()
            return
        }
        flow.beginSigningIn(provider: provider)
        push(.signIn(provider.id))
        await providers.signIn(provider)
    }

    func changeKey() {
        guard let provider = flow.provider else { return }
        let next: Screen = provider.id == FirstRunProviders.localProviderID ? .local : .key(provider.id)
        catalogTask?.cancel()
        flow.discard()
        replaceTop(with: next)
    }

    func changeModel() {
        showsAllModels = true
    }
}

enum LocalAddress {
    static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard let host = url.host(), !host.isEmpty else { return nil }
        return trimmed
    }
}
#endif
