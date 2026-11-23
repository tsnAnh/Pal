#if os(macOS)
import PalBotProfile

extension ProviderOnboardingModel {
    func checkHost(_ providerID: String) async {
        guard hostCheck != .installing else { return }
        hostCheck = .checking
        switch await client.hostCheck(providerID) {
        case .checked(let result): hostCheck = .checked(result)
        case .failed(let reason): hostCheck = .failed(reason)
        }
    }

    func installPlugin(_ providerID: String) async {
        guard hostCheck != .installing else { return }
        hostCheck = .installing
        switch await client.installPlugin(providerID) {
        case .installed: await checkHost(providerID)
        case .refused(let reason), .failed(let reason): hostCheck = .installFailed(reason)
        }
    }

    func continueWithClaude(_ providerID: String) async {
        await providers.refresh()
        guard let provider = providers.provider(id: providerID) else { return }
        begin(provider, credential: .external, owns: false)
    }
}
#endif
