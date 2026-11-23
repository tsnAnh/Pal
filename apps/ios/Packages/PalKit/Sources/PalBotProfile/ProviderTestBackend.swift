import Foundation
import PalProtocol

public struct ModelProvidersBackend: ProviderTestBackend {
    private let providers: ModelProvidersClient
    private let models: BotModelClient

    public init(providers: ModelProvidersClient, models: BotModelClient) {
        self.providers = providers
        self.models = models
    }

    public func runTest(_ request: ProviderTestRequest) async -> ProviderTestResult {
        await providers.test(request)
    }

    public func saveStaged(provider: String, apiKey: SecretString?, baseURL: String?) async -> String? {
        if let baseURL, !baseURL.isEmpty {
            switch await providers.setBaseURL(provider, to: baseURL) {
            case .saved, .reset: break
            case .invalid(let reason), .unsupported(let reason), .failed(let reason): return reason
            }
        }
        guard let apiKey, !apiKey.isEmpty else { return nil }
        return await providers.saveKey(provider, key: apiKey)
    }

    public func pin(_ choice: ModelChoice) async -> String? {
        switch await models.setModel(choice, confirmed: true) {
        case .saved: nil
        case .needsConfirmation(let reason), .failed(let reason): reason
        }
    }

    public func remove(provider: String) async -> Bool {
        switch await providers.remove(provider) {
        case .removed, .nothingToRemove: true
        case .stillSet, .refused, .unsupported, .failed: false
        }
    }
}

extension ModelCatalogProvider {
    public var defaultModel: String? { models.first }
}
