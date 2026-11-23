import Foundation

public struct FirstRunProviderChoice: Identifiable, Equatable, Sendable {
    public let provider: ModelProvider
    public let name: String
    public let blurb: String
    public let keyPage: String?
    public let tag: String?

    public var id: String { provider.id }

    public init(provider: ModelProvider, name: String, blurb: String, keyPage: String? = nil, tag: String? = nil) {
        self.provider = provider
        self.name = name
        self.blurb = blurb
        self.keyPage = keyPage
        self.tag = tag
    }
}

public struct FirstRunLayout: Equatable, Sendable {
    public let subscriptions: [FirstRunProviderChoice]
    public let keys: [FirstRunProviderChoice]
    public let local: ModelProvider?
    public let morePlans: [ModelProvider]
    public let moreKeys: [ModelProvider]

    public init(
        subscriptions: [FirstRunProviderChoice] = [], keys: [FirstRunProviderChoice] = [], local: ModelProvider? = nil,
        morePlans: [ModelProvider] = [], moreKeys: [ModelProvider] = []
    ) {
        self.subscriptions = subscriptions
        self.keys = keys
        self.local = local
        self.morePlans = morePlans
        self.moreKeys = moreKeys
    }
}

public enum FirstRunProviders {
    public static let localProviderID = "lmstudio"
    public static let experimentalTag = "Experimental"

    private struct Entry {
        let id: String
        let name: String
        let blurb: String
        var keyPage: String?
        var tag: String?
    }

    private static let subscriptionList = [
        Entry(
            id: "claude-subscription-directsdk-experimental", name: "Claude", blurb: "Claude Pro or Max, through Claude Direct SDK",
            tag: experimentalTag),
        Entry(id: "openai-codex", name: "OpenAI", blurb: "Your ChatGPT plan"),
        Entry(id: "nous", name: "Nous Portal", blurb: "Nous Research plan"),
    ]

    private static let keyList = [
        Entry(id: "anthropic", name: "Anthropic", blurb: "Claude models", keyPage: "console.anthropic.com"),
        Entry(id: "openrouter", name: "OpenRouter", blurb: "Hundreds of models, one key", keyPage: "openrouter.ai/keys"),
        Entry(id: "gemini", name: "Google Gemini", blurb: "Gemini models", keyPage: "aistudio.google.com/apikey"),
    ]

    private static let shortListIDs = Set((subscriptionList + keyList).map(\.id)).union([localProviderID])

    public static func layout(from providers: [ModelProvider]) -> FirstRunLayout {
        let offered = providers.filter(\.canSignIn)
        let others = offered.filter { !shortListIDs.contains($0.id) }
        return FirstRunLayout(
            subscriptions: choices(subscriptionList, in: offered),
            keys: choices(keyList, in: offered),
            local: offered.first { $0.id == localProviderID },
            morePlans: sortedByName(others.filter(\.isSubscription)),
            moreKeys: sortedByName(others.filter { $0.kind == .apiKey })
        )
    }

    public static func choice(for provider: ModelProvider) -> FirstRunProviderChoice {
        let entry = (subscriptionList + keyList).first { $0.id == provider.id }
        return entry.map { choice($0, provider) } ?? FirstRunProviderChoice(provider: provider, name: provider.name, blurb: "")
    }

    public static func hasConnected(_ providers: [ModelProvider]) -> Bool {
        providers.contains { $0.state == .set }
    }

    public static func filter(_ providers: [ModelProvider], query: String) -> [ModelProvider] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return providers }
        return providers.filter { $0.name.localizedStandardContains(needle) || $0.id.localizedStandardContains(needle) }
    }

    private static func choices(_ entries: [Entry], in providers: [ModelProvider]) -> [FirstRunProviderChoice] {
        entries.compactMap { entry in
            providers.first { $0.id == entry.id }.map { choice(entry, $0) }
        }
    }

    private static func choice(_ entry: Entry, _ provider: ModelProvider) -> FirstRunProviderChoice {
        FirstRunProviderChoice(provider: provider, name: entry.name, blurb: entry.blurb, keyPage: entry.keyPage, tag: entry.tag)
    }

    private static func sortedByName(_ providers: [ModelProvider]) -> [ModelProvider] {
        providers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

extension ModelProvidersModel {
    public var hasConnectedProvider: Bool { FirstRunProviders.hasConnected(providers) }

    public var layout: FirstRunLayout { FirstRunProviders.layout(from: providers) }

    public var isSigningInAny: Bool { rows.values.contains(.working(.signingIn)) }

    public var apiKeyServiceKeys: Set<String> {
        Set(providers.filter { $0.kind == .apiKey }.map { ModelProvidersClient.serviceKey + $0.id })
    }

    public var providerServiceKeys: Set<String> {
        Set(providers.map { ModelProvidersClient.serviceKey + $0.id })
    }

    public func provider(id: String) -> ModelProvider? {
        providers.first { $0.id == id }
    }
}
