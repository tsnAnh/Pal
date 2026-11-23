import Foundation
import Testing

@testable import PalBotProfile
@testable import PalProtocol

private func row(_ id: String, name: String? = nil, kind: ModelProviderKind = .apiKey, state: ModelProviderState = .notSet) -> ModelProvider {
    ModelProvider(id: id, name: name ?? id.capitalized, kind: kind, state: state)
}

private let directSDK = "claude-subscription-directsdk-experimental"

@Suite("First run layout")
struct FirstRunLayoutTests {
    private let catalogue = [
        row("mistral", name: "Mistral"),
        row("nous", name: "Nous Portal", kind: .deviceCode),
        row("gemini", name: "Gemini"),
        row(directSDK, name: "Claude (Direct SDK)", kind: .cliPlan),
        row("anthropic", name: "Anthropic"),
        row("openai-codex", name: "OpenAI Codex", kind: .deviceCode),
        row("openrouter", name: "OpenRouter"),
        row("lmstudio", name: "LM Studio"),
        row("zai", name: "Z.ai"),
        row("copilot", name: "GitHub Copilot", kind: .deviceCode),
        row("xai-oauth", name: "xAI", kind: .oauthPaste),
        row("bedrock", name: "AWS Bedrock", kind: .unsupported, state: .unsupported),
        row("mystery", name: "Mystery", kind: .unknown),
    ]

    @Test("the short lists keep their order, names, blurbs, key pages and the Experimental tag")
    func shortLists() {
        let layout = FirstRunProviders.layout(from: catalogue)
        #expect(layout.subscriptions.map(\.id) == [directSDK, "openai-codex", "nous"])
        #expect(layout.subscriptions.map(\.name) == ["Claude", "OpenAI", "Nous Portal"])
        #expect(layout.subscriptions.map(\.blurb) == ["Claude Pro or Max, through Claude Direct SDK", "Your ChatGPT plan", "Nous Research plan"])
        #expect(layout.subscriptions.map(\.tag) == ["Experimental", nil, nil])
        #expect(layout.subscriptions.map(\.keyPage) == [nil, nil, nil])
        #expect(layout.keys.map(\.id) == ["anthropic", "openrouter", "gemini"])
        #expect(layout.keys.map(\.name) == ["Anthropic", "OpenRouter", "Google Gemini"])
        #expect(layout.keys.map(\.blurb) == ["Claude models", "Hundreds of models, one key", "Gemini models"])
        #expect(layout.keys.map(\.keyPage) == ["console.anthropic.com", "openrouter.ai/keys", "aistudio.google.com/apikey"])
        #expect(layout.keys.map(\.tag) == [nil, nil, nil])
        #expect(layout.subscriptions.first?.provider.kind == .cliPlan)
    }

    @Test("the rest follow the row kind, sorted by name, and the local address stands alone")
    func membership() {
        let layout = FirstRunProviders.layout(from: catalogue)
        #expect(layout.local?.id == "lmstudio")
        #expect(layout.morePlans.map(\.id) == ["copilot", "xai-oauth"])
        #expect(layout.moreKeys.map(\.id) == ["mistral", "zai"])
        let everywhere = layout.subscriptions.map(\.id) + layout.keys.map(\.id) + layout.morePlans.map(\.id) + layout.moreKeys.map(\.id)
        #expect(!everywhere.contains("lmstudio") && !everywhere.contains("bedrock") && !everywhere.contains("mystery"))
        #expect(Set(everywhere).count == everywhere.count)
    }

    @Test("a plan on the computer that is not set up yet still counts as a plan to offer")
    func hostPlansAreOffered() {
        let layout = FirstRunProviders.layout(from: [row("some-cli", name: "Some CLI", kind: .cliPlan, state: .notSet)])
        #expect(layout.morePlans.map(\.id) == ["some-cli"] && layout.subscriptions.isEmpty)
    }

    @Test("rows the engine does not return or cannot sign in are left out, and the layout can be empty")
    func absentRows() {
        let layout = FirstRunProviders.layout(
            from: [
                row("anthropic", kind: .unsupported, state: .unsupported), row("lmstudio", state: .unsupported),
                row("nous", kind: .deviceCode, state: .unsupported),
            ])
        #expect(layout == FirstRunLayout())
        #expect(FirstRunProviders.layout(from: []) == FirstRunLayout())
        #expect(FirstRunProviders.layout(from: [row("openrouter")]).keys.map(\.id) == ["openrouter"])
    }

    @Test("a choice is the short-list entry or a plain one named after the provider")
    func choices() {
        let known = FirstRunProviders.choice(for: row("openrouter"))
        #expect(known.name == "OpenRouter" && known.blurb == "Hundreds of models, one key" && known.keyPage == "openrouter.ai/keys")
        let tagged = FirstRunProviders.choice(for: row(directSDK, kind: .cliPlan))
        #expect(tagged.tag == "Experimental" && tagged.name == "Claude")
        let generic = FirstRunProviders.choice(for: row("zai", name: "Z.ai"))
        #expect(generic.name == "Z.ai" && generic.blurb.isEmpty && generic.keyPage == nil && generic.tag == nil && generic.id == "zai")
    }

    @Test("filter matches the name or the id and an empty query keeps everything")
    func filtering() {
        let all = catalogue
        #expect(FirstRunProviders.filter(all, query: "").count == all.count)
        #expect(FirstRunProviders.filter(all, query: "   ").count == all.count)
        #expect(FirstRunProviders.filter(all, query: "codex").map(\.id) == ["openai-codex"])
        #expect(FirstRunProviders.filter(all, query: "LM STUDIO").map(\.id) == ["lmstudio"])
        #expect(FirstRunProviders.filter(all, query: "xai-o").map(\.id) == ["xai-oauth"])
        #expect(FirstRunProviders.filter(all, query: "zzzz").isEmpty)
    }

    @Test("only a set provider counts as connected")
    func connected() {
        #expect(!FirstRunProviders.hasConnected([row("anthropic"), row("openrouter", state: .expired)]))
        #expect(FirstRunProviders.hasConnected([row("anthropic"), row("openrouter", state: .set)]))
        #expect(!FirstRunProviders.hasConnected([]))
    }
}

@MainActor
@Suite("Provider plans on the computer")
struct CliPlanProviderTests {
    private func wire(state: String = "not_set", reason: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["id": .string(directSDK), "name": "Claude (Direct SDK)", "kind": "cli_plan", "state": .string(state)]
        if let reason { object["reason"] = .string(reason) }
        return .object(object)
    }

    @Test("cli_plan decodes, can sign in unless unsupported, and an unknown kind still cannot")
    func decoding() throws {
        let plan = try wire().decoded(as: ModelProvider.self)
        #expect(plan.kind == .cliPlan && plan.canSignIn && plan.isSubscription)
        #expect(try wire(state: "unsupported").decoded(as: ModelProvider.self).canSignIn == false)
        let future = try JSONValue.object(["id": "x", "name": "X", "kind": "from_the_future", "state": "not_set"]).decoded(as: ModelProvider.self)
        #expect(future.kind == .unknown && !future.canSignIn && !future.isSubscription)
    }

    @Test("a subscription is a device code, a pasted sign-in or a plan on the computer")
    func subscriptions() {
        #expect(row("a", kind: .deviceCode).isSubscription && row("a", kind: .oauthPaste).isSubscription && row("a", kind: .cliPlan).isSubscription)
        #expect(!row("a", kind: .apiKey).isSubscription && !row("a", kind: .unsupported).isSubscription && !row("a", kind: .unknown).isSubscription)
    }

    @Test("a plan sits under the computer until it is set up, then under Connected")
    func groups() throws {
        #expect(try wire(state: "not_set").decoded(as: ModelProvider.self).group == .onHost)
        #expect(try wire(state: "unknown").decoded(as: ModelProvider.self).group == .onHost)
        #expect(try wire(state: "set").decoded(as: ModelProvider.self).group == .connected)
        #expect(try wire(state: "expired").decoded(as: ModelProvider.self).group == .connected)
        #expect(try wire(state: "unsupported").decoded(as: ModelProvider.self).group == .onHost)
    }

    @Test("a plan row has no action and says where to set it up")
    func face() throws {
        let missing = ModelProviderSorting.face(try wire().decoded(as: ModelProvider.self), status: .idle)
        #expect(missing.primaryAction == nil)
        #expect(missing.detail == "Set up Claude Code and its plugin on the computer that runs Pal.")
        let reasoned = ModelProviderSorting.face(try wire(reason: "Claude Code isn't installed.").decoded(as: ModelProvider.self), status: .idle)
        #expect(reasoned.primaryAction == nil && reasoned.detail == "Claude Code isn't installed.")
        let ready = ModelProviderSorting.face(try wire(state: "set").decoded(as: ModelProvider.self), status: .idle)
        #expect(ready.primaryAction == nil && ready.detail == "Signed in")
    }

    @Test("signing in a plan never starts an app sign-in")
    func noSignIn() async {
        let bots = ScriptedBots()
        bots.script("model.providers.list", ["providers": [wire()]])
        let model = ModelProvidersModel(client: ModelProvidersClient(gateway: bots.gateway, profile: "atlas"), surfaces: scratchSurfaces())
        await model.load()
        await model.signIn(model.providers[0])
        #expect(bots.calls(to: "auth.begin").isEmpty)
        #expect(model.status(of: directSDK) == .idle)
        #expect(model.sections.map(\.group) == [.connected, .onHost])
    }

    @Test("the model exposes the layout, every service key and a lookup by id")
    func modelAccessors() async {
        let bots = ScriptedBots()
        bots.script("model.providers.list", ["providers": [wire(), ["id": "openrouter", "name": "OpenRouter", "kind": "api_key", "state": "set"]]])
        let model = ModelProvidersModel(client: ModelProvidersClient(gateway: bots.gateway, profile: "atlas"), surfaces: scratchSurfaces())
        await model.load()
        #expect(model.providerServiceKeys == ["provider:\(directSDK)", "provider:openrouter"])
        #expect(model.apiKeyServiceKeys == ["provider:openrouter"])
        #expect(model.provider(id: "openrouter")?.state == .set && model.provider(id: "nope") == nil)
        #expect(model.layout.subscriptions.map(\.id) == [directSDK] && model.layout.keys.map(\.id) == ["openrouter"])
        #expect(model.hasConnectedProvider && !model.isSigningInAny)
    }
}
