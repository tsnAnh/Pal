import Foundation

public struct FirstRunProviderChoice: Identifiable, Equatable, Sendable {
    public let provider: ModelProvider
    public let name: String
    public let blurb: String
    public let keyPage: String?

    public var id: String { provider.id }
}

public enum FirstRunProviders {
    private struct Entry {
        let id: String
        let name: String
        let blurb: String
        var keyPage: String?
    }

    private static let shortList = [
        Entry(id: "anthropic", name: "Anthropic", blurb: "Claude models", keyPage: "console.anthropic.com"),
        Entry(id: "openai-codex", name: "OpenAI", blurb: "GPT models, sign in with ChatGPT"),
        Entry(id: "openrouter", name: "OpenRouter", blurb: "Hundreds of models, one key", keyPage: "openrouter.ai/keys"),
        Entry(id: "gemini", name: "Google Gemini", blurb: "Gemini models", keyPage: "aistudio.google.com/apikey"),
        Entry(id: "nous", name: "Nous Portal", blurb: "Nous Research models"),
    ]

    public static func choices(from providers: [ModelProvider]) -> [FirstRunProviderChoice] {
        shortList.compactMap { entry in
            guard let provider = providers.first(where: { $0.id == entry.id }), provider.canSignIn else { return nil }
            return FirstRunProviderChoice(provider: provider, name: entry.name, blurb: entry.blurb, keyPage: entry.keyPage)
        }
    }

    public static func hasConnected(_ providers: [ModelProvider]) -> Bool {
        providers.contains { $0.state == .set }
    }
}

extension ModelProvidersModel {
    public var hasConnectedProvider: Bool { FirstRunProviders.hasConnected(providers) }

    public var firstRunChoices: [FirstRunProviderChoice] { FirstRunProviders.choices(from: providers) }

    public var isSigningInAny: Bool { rows.values.contains(.working(.signingIn)) }

    public var allSignInProviders: [ModelProvider] {
        sections.filter { $0.group != .onHost }.flatMap(\.providers).filter(\.canSignIn)
    }

    public var apiKeyServiceKeys: Set<String> {
        Set(providers.filter { $0.kind == .apiKey }.map { ModelProvidersClient.serviceKey + $0.id })
    }
}
