import Foundation
import Testing

@testable import PalBotProfile
@testable import PalDevice
@testable import PalProtocol
@testable import PalTransport

private func providerRow(
    _ id: String = "openrouter",
    name: String = "OpenRouter",
    kind: String = "api_key",
    state: String = "not_set",
    scope: String = "profile",
    editable: Bool = false,
    baseURL: String? = nil,
    defaultBaseURL: String? = nil,
    reason: String? = nil,
    canRemove: Bool = false
) -> JSONValue {
    var object: [String: JSONValue] = [
        "id": .string(id), "name": .string(name), "kind": .string(kind), "state": .string(state), "scope": .string(scope),
        "base_url_editable": .bool(editable), "can_remove": .bool(canRemove),
    ]
    if let baseURL { object["base_url"] = .string(baseURL) }
    if let defaultBaseURL { object["default_base_url"] = .string(defaultBaseURL) }
    if let reason { object["reason"] = .string(reason) }
    return .object(object)
}

private func listing(_ rows: JSONValue...) -> JSONValue {
    ["profile": "atlas", "providers": .array(rows)]
}

private func outcome(_ outcome: String, reason: String? = nil, provider: JSONValue? = nil, requestID: String? = nil) -> JSONValue {
    var object: [String: JSONValue] = ["outcome": .string(outcome)]
    if let reason { object["reason"] = .string(reason) }
    if let provider { object["provider"] = provider }
    if let requestID { object["request_id"] = .string(requestID) }
    return .object(object)
}

@Suite("Model providers client")
struct ModelProvidersClientTests {
    private func client(_ bots: ScriptedBots, profile: String? = "atlas") -> ModelProvidersClient {
        ModelProvidersClient(gateway: bots.gateway, profile: profile)
    }

    @Test("list decodes every kind and state, with an unknown fallback")
    func decodesEverything() async throws {
        let bots = ScriptedBots()
        bots.script(
            "model.providers.list",
            listing(
                providerRow("a", kind: "api_key", state: "set", canRemove: true),
                providerRow("b", kind: "device_code", state: "expired", scope: "account"),
                providerRow("c", kind: "unsupported", state: "unsupported", reason: "Needs a setup this app can't do."),
                providerRow("d", kind: "from_the_future", state: "from_the_future", scope: "from_the_future"),
                providerRow("e", editable: true, baseURL: "https://proxy.example.com/v1", defaultBaseURL: "https://api.example.com/v1"),
                providerRow("f", kind: "oauth_paste", state: "expired")
            ))
        let providers = try await client(bots).list()
        #expect(providers.map(\.kind) == [.apiKey, .deviceCode, .unsupported, .unknown, .apiKey, .oauthPaste])
        #expect(providers.map(\.state) == [.set, .expired, .unsupported, .unknown, .notSet, .expired])
        #expect(providers.map(\.scope) == [.profile, .account, .profile, .unknown, .profile, .profile])
        #expect(providers[0].canRemove && !providers[1].canRemove)
        #expect(providers[2].reason == "Needs a setup this app can't do.")
        #expect(providers[4].baseURLEditable)
        #expect(providers[4].baseURL == "https://proxy.example.com/v1")
        #expect(providers[4].defaultBaseURL == "https://api.example.com/v1")
        #expect(providers.map(\.canSignIn) == [true, true, false, false, true, true])
    }

    @Test("list and remove params carry the profile and never a secret")
    func requestShapes() async throws {
        let bots = ScriptedBots()
        bots.script("model.providers.list", listing())
        bots.script("model.providers.remove", outcome("removed"))
        bots.script("model.providers.set_base_url", outcome("saved"))
        let client = client(bots)
        _ = try await client.list()
        _ = await client.remove("openrouter")
        _ = await client.setBaseURL("openrouter", to: "https://proxy.example.com/v1")
        #expect(bots.calls(to: "model.providers.list").first?.params == ["profile": "atlas"])
        #expect(bots.calls(to: "model.providers.remove").first?.params == ["provider": "openrouter", "profile": "atlas"])
        #expect(
            bots.calls(to: "model.providers.set_base_url").first?.params
                == ["provider": "openrouter", "base_url": "https://proxy.example.com/v1", "profile": "atlas"])
        for call in bots.calls {
            let keys = Set(call.params.keys)
            #expect(keys.isDisjoint(with: ["value", "api_key", "key", "token", "secret"]))
        }
    }

    @Test("no profile is omitted from params and a reset sends null")
    func resetAndNoProfile() async {
        let bots = ScriptedBots()
        bots.script("model.providers.set_base_url", outcome("reset"))
        let result = await client(bots, profile: nil).setBaseURL("openrouter", to: nil)
        #expect(result == .reset(nil))
        #expect(bots.calls(to: "model.providers.set_base_url").first?.params == ["provider": "openrouter", "base_url": .null])
    }

    @Test("remove maps every outcome and keeps the gateway reason")
    func removeOutcomes() async {
        let updated = providerRow("openrouter", state: "set", canRemove: true)
        let expected: [(String, ModelProviderRemoval)] = [
            ("removed", .removed(nil)),
            ("nothing_to_remove", .nothingToRemove(nil)),
            ("still_set", .stillSet("Still set by another setting.", nil)),
            ("refused", .refused("Still set by another setting.")),
            ("unsupported", .unsupported("Still set by another setting.")),
            ("failed", .failed("Still set by another setting.")),
            ("surprise", .failed("Still set by another setting.")),
        ]
        for (wire, result) in expected {
            let bots = ScriptedBots()
            bots.script("model.providers.remove", outcome(wire, reason: "Still set by another setting."))
            #expect(await client(bots).remove("openrouter") == result)
        }
        let bots = ScriptedBots()
        bots.script("model.providers.remove", outcome("still_set", reason: "x", provider: updated))
        guard case .stillSet(_, let provider?) = await client(bots).remove("openrouter") else {
            Issue.record("expected the updated provider")
            return
        }
        #expect(provider.state == .set)
    }

    @Test("a missing reason falls back to plain words and a transport error is a failure")
    func removeFallbacks() async {
        let bots = ScriptedBots()
        bots.script("model.providers.remove", outcome("failed"))
        #expect(await client(bots).remove("x") == .failed(ModelProvidersClient.couldNotRemove))
        let broken = ScriptedBots()
        broken.script("model.providers.remove") { _ in throw GatewayTransportError.closed(.normal) }
        #expect(await client(broken).remove("x") == .failed(ModelProvidersClient.couldNotRemove))
    }

    @Test("set base url maps every outcome")
    func baseURLOutcomes() async {
        let expected: [(String, ModelProviderBaseURLChange)] = [
            ("saved", .saved(nil)), ("reset", .reset(nil)), ("invalid", .invalid("Use an https address.")),
            ("unsupported", .unsupported("Use an https address.")), ("failed", .failed("Use an https address.")),
        ]
        for (wire, result) in expected {
            let bots = ScriptedBots()
            bots.script("model.providers.set_base_url", outcome(wire, reason: "Use an https address."))
            #expect(await client(bots).setBaseURL("openrouter", to: "http://x") == result)
        }
        let broken = ScriptedBots()
        broken.script("model.providers.set_base_url") { _ in throw GatewayTransportError.closed(.normal) }
        #expect(await client(broken).setBaseURL("openrouter", to: nil) == .failed(ModelProvidersClient.couldNotSaveAddress))
    }

    @Test("auth.begin names the provider service and maps its outcomes")
    func beginSignIn() async {
        let started = ScriptedBots()
        started.script("auth.begin", outcome("started", requestID: "r1"))
        #expect(await client(started).beginSignIn("openrouter") == .started(requestID: "r1"))
        #expect(started.calls(to: "auth.begin").first?.params == ["service": "provider:openrouter"])

        let expected: [(String, ModelProviderSignInStart)] = [
            ("unsupported", .unsupported("Not here.")), ("refused", .refused("Not here.")), ("unavailable", .unavailable("Not here.")),
        ]
        for (wire, result) in expected {
            let bots = ScriptedBots()
            bots.script("auth.begin", outcome(wire, reason: "Not here."))
            #expect(await client(bots).beginSignIn("openrouter") == result)
        }
        let broken = ScriptedBots()
        broken.script("auth.begin") { _ in throw GatewayTransportError.closed(.normal) }
        #expect(await client(broken).beginSignIn("openrouter") == .unavailable(ModelProvidersClient.couldNotStart))
    }
}

@Suite("Sign-in resolved reason")
struct AuthResolvedReasonTests {
    @Test("reason is decoded, empty and absent are nil")
    func reason() throws {
        func event(_ reason: JSONValue?) -> GatewayEvent {
            var payload: [String: JSONValue] = ["request_id": "r1", "outcome": "failed"]
            if let reason { payload["reason"] = reason }
            return GatewayEvent(type: "auth.resolved", payload: .object(payload))
        }
        #expect(try #require(AuthResolvedEvent(event: event("That key was rejected."))).reason == "That key was rejected.")
        #expect(try #require(AuthResolvedEvent(event: event(""))).reason == nil)
        #expect(try #require(AuthResolvedEvent(event: event(nil))).reason == nil)
        #expect(try #require(AuthResolvedEvent(event: event(.null))).reason == nil)
    }

    @MainActor
    @Test("the dialog's failed state shows the reason and a resolution is published")
    func dialogShowsReason() async throws {
        let center = ServiceSignInCenter(call: { _, _ in ["recorded": true] }, openBrowser: { _ in })
        center.receive(
            GatewayEvent(
                type: "auth.required",
                payload: [
                    "request_id": "r1", "service": "provider:openrouter", "service_name": "OpenRouter", "bot": "atlas",
                    "reason": "missing", "flow": "api_key",
                ]))
        center.receive(
            GatewayEvent(
                type: "auth.resolved",
                payload: ["request_id": "r1", "outcome": "failed", "reason": "That key was rejected."]))
        #expect(center.current?.phase == .failed("That key was rejected."))
        let resolution = try #require(center.lastResolution)
        #expect(resolution.service == "provider:openrouter")
        #expect(resolution.reason == "That key was rejected.")
        #expect(resolution.outcome == .failed)
    }

    @MainActor
    @Test("a declined request still publishes a resolution after the dialog is gone")
    func declinedResolution() async throws {
        let center = ServiceSignInCenter(call: { _, _ in [:] }, openBrowser: { _ in })
        center.receive(
            GatewayEvent(
                type: "auth.required",
                payload: ["request_id": "r1", "service": "provider:openrouter", "bot": "atlas", "flow": "api_key"]))
        await center.notNow()
        center.receive(GatewayEvent(type: "auth.resolved", payload: ["request_id": "r1", "outcome": "declined"]))
        let resolution = try #require(center.lastResolution)
        #expect(resolution.requestID == "r1")
        #expect(resolution.outcome == .declined)
    }
}

@MainActor
@Suite("Model providers model")
struct ModelProvidersModelTests {
    private func model(_ bots: ScriptedBots) -> ModelProvidersModel {
        ModelProvidersModel(client: ModelProvidersClient(gateway: bots.gateway, profile: "atlas"))
    }

    private func loaded(_ bots: ScriptedBots) async -> ModelProvidersModel {
        let model = model(bots)
        await model.load()
        return model
    }

    @Test("load fills the list, and a failed reload keeps it and flags the failure")
    func load() async {
        let bots = ScriptedBots()
        bots.script("model.providers.list", listing(providerRow()))
        let model = await loaded(bots)
        #expect(model.providers.count == 1 && model.hasLoaded && !model.loadFailed)
        bots.script("model.providers.list") { _ in throw GatewayTransportError.closed(.normal) }
        await model.load()
        #expect(model.providers.count == 1 && model.loadFailed)
    }

    @Test("set key: working, then refreshed and succeeded once signed_in arrives")
    func setKey() async {
        let bots = ScriptedBots()
        bots.script("model.providers.list", listing(providerRow(state: "not_set")))
        bots.script("model.providers.list", listing(providerRow(state: "set", canRemove: true)))
        bots.script("auth.begin", outcome("started", requestID: "r1"))
        let model = await loaded(bots)
        let provider = model.providers[0]
        await model.signIn(provider)
        #expect(model.status(of: "openrouter") == .working(.signingIn))
        await model.signInResolved(requestID: "r1", service: "provider:openrouter", outcome: .signedIn, reason: nil)
        #expect(model.providers[0].state == .set)
        #expect(model.status(of: "openrouter") == .succeeded("Key saved."))
        #expect(bots.calls(to: "model.providers.list").count == 2)
    }

    @Test("a resolution for another request is ignored")
    func otherRequest() async {
        let bots = ScriptedBots()
        bots.script("model.providers.list", listing(providerRow()))
        bots.script("auth.begin", outcome("started", requestID: "r1"))
        let model = await loaded(bots)
        await model.signIn(model.providers[0])
        await model.signInResolved(requestID: "other", service: "provider:someone-else", outcome: .signedIn, reason: nil)
        #expect(model.status(of: "openrouter") == .working(.signingIn))
    }

    @Test("cancel, timeout and failure each end the row with their own feedback")
    func endings() async {
        let cases: [(ServiceSignInOutcome, String?, ModelProvidersModel.RowStatus)] = [
            (.declined, nil, .cancelled),
            (.timedOut, nil, .failed("Sign-in took too long. Try again.")),
            (.failed, "That key was rejected.", .failed("That key was rejected.")),
            (.failed, nil, .failed("Sign-in didn't finish. Try again.")),
        ]
        for (result, reason, expected) in cases {
            let bots = ScriptedBots()
            bots.script("model.providers.list", listing(providerRow()))
            bots.script("auth.begin", outcome("started", requestID: "r1"))
            let model = await loaded(bots)
            await model.signIn(model.providers[0])
            await model.signInResolved(requestID: "r1", service: nil, outcome: result, reason: reason)
            #expect(model.status(of: "openrouter") == expected)
        }
    }

    @Test("auth.begin refusal shows the gateway reason and leaves the row idle for a retry")
    func beginRefused() async {
        let bots = ScriptedBots()
        bots.script("model.providers.list", listing(providerRow()))
        bots.script("auth.begin", outcome("refused", reason: "Only the main connection can do that."))
        let model = await loaded(bots)
        await model.signIn(model.providers[0])
        #expect(model.status(of: "openrouter") == .failed("Only the main connection can do that."))
        #expect(!model.isWorking("openrouter"))
    }

    @Test("unsupported providers offer no sign-in")
    func unsupportedNoSignIn() async {
        let bots = ScriptedBots()
        bots.script("model.providers.list", listing(providerRow(kind: "unsupported", state: "unsupported", reason: "Not here.")))
        let model = await loaded(bots)
        await model.signIn(model.providers[0])
        #expect(bots.calls(to: "auth.begin").isEmpty)
    }

    @Test("remove clears the row, and still_set shows the reason")
    func remove() async {
        let bots = ScriptedBots()
        bots.script("model.providers.list", listing(providerRow(state: "set", canRemove: true)))
        bots.script("model.providers.remove", outcome("removed", provider: providerRow(state: "not_set")))
        let model = await loaded(bots)
        await model.remove(model.providers[0])
        #expect(model.providers[0].state == .notSet)
        #expect(model.status(of: "openrouter") == .succeeded("Removed."))

        let stuck = ScriptedBots()
        stuck.script("model.providers.list", listing(providerRow(state: "set", canRemove: true)))
        stuck.script("model.providers.remove", outcome("still_set", reason: "Still set by another setting."))
        stuck.script("model.providers.list", listing(providerRow(state: "set", canRemove: true)))
        let other = await loaded(stuck)
        await other.remove(other.providers[0])
        #expect(other.providers[0].state == .set)
        #expect(other.status(of: "openrouter") == .failed("Still set by another setting."))
    }

    @Test("a provider that cannot be removed is never sent for removal")
    func removeGuard() async {
        let bots = ScriptedBots()
        bots.script("model.providers.list", listing(providerRow(state: "set", canRemove: false)))
        let model = await loaded(bots)
        await model.remove(model.providers[0])
        #expect(bots.calls(to: "model.providers.remove").isEmpty)
    }

    @Test("base url: invalid shows the reason, save and reset update the row")
    func baseURL() async {
        let bots = ScriptedBots()
        bots.script(
            "model.providers.list",
            listing(providerRow(editable: true, baseURL: "https://old.example.com", defaultBaseURL: "https://api.example.com")))
        bots.script("model.providers.set_base_url", outcome("invalid", reason: "Use an https address."))
        bots.script(
            "model.providers.set_base_url",
            outcome("saved", provider: providerRow(editable: true, baseURL: "https://new.example.com", defaultBaseURL: "https://api.example.com")))
        bots.script(
            "model.providers.set_base_url",
            outcome("reset", provider: providerRow(editable: true, baseURL: nil, defaultBaseURL: "https://api.example.com")))
        let model = await loaded(bots)
        var provider = model.providers[0]
        model.setAddress("http://nope", for: provider)
        #expect(model.addressIsDirty(for: provider))
        await model.saveAddress(provider)
        #expect(model.status(of: "openrouter") == .failed("Use an https address."))
        #expect(model.address(for: provider) == "http://nope")

        model.setAddress("  https://new.example.com ", for: provider)
        await model.saveAddress(provider)
        provider = model.providers[0]
        #expect(provider.baseURL == "https://new.example.com")
        #expect(model.status(of: "openrouter") == .succeeded("Address saved."))
        #expect(!model.addressIsDirty(for: provider))
        #expect(bots.calls(to: "model.providers.set_base_url").last?.params["base_url"] == "https://new.example.com")

        await model.useDefaultAddress(provider)
        #expect(model.providers[0].baseURL == nil)
        #expect(model.status(of: "openrouter") == .succeeded("Using the default address."))
    }

    @Test("an empty address is rejected locally")
    func emptyAddress() async {
        let bots = ScriptedBots()
        bots.script("model.providers.list", listing(providerRow(editable: true)))
        let model = await loaded(bots)
        model.setAddress("   ", for: model.providers[0])
        await model.saveAddress(model.providers[0])
        #expect(model.status(of: "openrouter") == .failed("Enter an address, or use the default."))
        #expect(bots.calls(to: "model.providers.set_base_url").isEmpty)
    }
}
