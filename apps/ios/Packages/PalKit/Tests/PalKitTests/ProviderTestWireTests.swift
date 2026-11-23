import Foundation
import Testing

@testable import PalBotProfile
@testable import PalProtocol
@testable import PalTransport

private func testResultWire(
    ok: Bool = true, latency: JSONValue = 412, preview: JSONValue? = "Hi.", error: JSONValue? = nil
) -> JSONValue {
    var object: [String: JSONValue] = ["ok": .bool(ok), "provider": "openrouter", "model": "gpt-5", "latency_ms": latency]
    if let preview { object["reply_preview"] = preview }
    if let error { object["error"] = error }
    return .object(object)
}

private func errorWire(_ kind: String, reason: JSONValue? = "That didn't work.") -> JSONValue {
    var object: [String: JSONValue] = ["code": "bad", "retryable": true, "kind": .string(kind)]
    if let reason { object["reason"] = reason }
    return .object(object)
}

private func hostWire(cli: Bool = true, signedIn: Bool = true, plugin: Bool = true) -> JSONValue {
    [
        "cli_found": .bool(cli), "cli_version": "2.1.0", "signed_in": .bool(signedIn), "plan": "Max",
        "plugin_installed": .bool(plugin), "plugin_version": "0.3.0", "install_hint": "npm i -g claude", "disclosure": "Runs on this computer.",
    ]
}

@Suite("Provider test wire")
struct ProviderTestWireTests {
    private func client(_ bots: ScriptedBots, profile: String? = "atlas") -> ModelProvidersClient {
        ModelProvidersClient(gateway: bots.gateway, profile: profile)
    }

    @Test("a passing result decodes with its latency and preview")
    func decodesAPass() throws {
        let result = try testResultWire().decoded(as: ProviderTestResult.self)
        #expect(result == ProviderTestResult(ok: true, provider: "openrouter", model: "gpt-5", latencyMilliseconds: 412, replyPreview: "Hi."))
        let sparse = try testResultWire(latency: 412.6, preview: "").decoded(as: ProviderTestResult.self)
        #expect(sparse.latencyMilliseconds == 413 && sparse.replyPreview == nil && sparse.error == nil)
    }

    @Test(
        "every failure kind decodes and an unknown one is other",
        arguments: [
            ("auth", ProviderTestFailureKind.auth), ("network", .network), ("timeout", .timeout), ("model", .model), ("quota", .quota),
            ("unsupported", .unsupported), ("other", .other), ("from_the_future", .other), ("", .other),
        ])
    func failureKinds(wire: String, expected: ProviderTestFailureKind) throws {
        let result = try testResultWire(ok: false, error: errorWire(wire)).decoded(as: ProviderTestResult.self)
        #expect(!result.ok)
        #expect(result.error == ProviderTestError(code: "bad", reason: "That didn't work.", retryable: true, kind: expected))
    }

    @Test("an error without a reason still has plain words and a result without ok is rejected")
    func tolerance() throws {
        let result = try testResultWire(ok: false, error: errorWire("auth", reason: nil)).decoded(as: ProviderTestResult.self)
        #expect(result.error?.reason == ModelProvidersClient.testDidNotPass)
        #expect(throws: (any Error).self) { try JSONValue.object(["provider": "x"]).decoded(as: ProviderTestResult.self) }
    }

    @Test("the request carries the staged key and address, the profile, and a clamped timeout")
    func requestShape() async {
        let bots = ScriptedBots()
        bots.script("model.providers.test", testResultWire())
        let key = "sk-fake-\(UUID().uuidString)"
        let result = await client(bots).test(
            ProviderTestRequest(provider: "lmstudio", model: "qwen", baseURL: "http://localhost:1234/v1", apiKey: SecretString(key), timeoutSeconds: 500))
        #expect(result.ok)
        #expect(
            bots.calls(to: "model.providers.test").first?.params == [
                "provider": "lmstudio", "model": "qwen", "base_url": "http://localhost:1234/v1", "api_key": .string(key), "timeout_s": 60,
                "profile": "atlas",
            ])
    }

    @Test("a written credential sends no key, no address and the default timeout, and no profile when there is none")
    func writtenRequestShape() async {
        let bots = ScriptedBots()
        bots.script("model.providers.test", testResultWire())
        _ = await client(bots, profile: nil).test(ProviderTestRequest(provider: "openai-codex", model: "gpt-5"))
        #expect(
            bots.calls(to: "model.providers.test").first?.params == ["provider": "openai-codex", "model": "gpt-5", "timeout_s": 25])
        #expect(ProviderTestRequest(provider: "a", model: "b", timeoutSeconds: 0).timeoutSeconds == 1)
        #expect(ProviderTestRequest(provider: "a", model: "b", timeoutSeconds: -5).timeoutSeconds == 1)
        #expect(ProviderTestRequest(provider: "a", model: "b", timeoutSeconds: 45).timeoutSeconds == 45)
        #expect(ProviderTestRequest(provider: "a", model: "b", baseURL: "", apiKey: SecretString("")).wireParams["api_key"] == nil)
        #expect(ProviderTestRequest(provider: "a", model: "b", baseURL: "").wireParams["base_url"] == nil)
    }

    @Test("a transport failure or an undecodable reply is a failed test, not an error")
    func neverThrows() async {
        let expected = ProviderTestError(code: "client_error", reason: "Couldn't run the test. Try again in a moment.", retryable: true, kind: .other)
        let broken = ScriptedBots()
        broken.script("model.providers.test") { _ in throw GatewayTransportError.closed(.normal) }
        let thrown = await client(broken).test(ProviderTestRequest(provider: "a", model: "b"))
        #expect(!thrown.ok && thrown.error == expected)

        let garbled = ScriptedBots()
        garbled.script("model.providers.test", ["nonsense": true])
        let decoded = await client(garbled).test(ProviderTestRequest(provider: "a", model: "b"))
        #expect(!decoded.ok && decoded.error == expected)
    }

    @Test("a failed test is a normal result the gateway reports")
    func failedIsNormal() async {
        let bots = ScriptedBots()
        bots.script("model.providers.test", testResultWire(ok: false, preview: nil, error: errorWire("auth", reason: "That key was rejected.")))
        let result = await client(bots).test(ProviderTestRequest(provider: "a", model: "b"))
        #expect(!result.ok && result.error?.kind == .auth && result.error?.reason == "That key was rejected.")
    }

    @Test("save key sends the slug and key to the profile and never repeats the key in a reason")
    func saveKey() async {
        let key = "sk-fake-\(UUID().uuidString)"
        let bots = ScriptedBots()
        bots.script("model.save_key", ["provider": ["slug": "openrouter"]])
        #expect(await client(bots).saveKey("openrouter", key: SecretString(key)) == nil)
        #expect(bots.calls(to: "model.save_key").first?.params == ["slug": "openrouter", "api_key": .string(key), "profile": "atlas"])

        let broken = ScriptedBots()
        broken.script("model.save_key") { _ in throw GatewayTransportError.closed(.normal) }
        let reason = await client(broken).saveKey("openrouter", key: SecretString(key))
        #expect(reason == ModelProvidersClient.couldNotSaveKey && !(reason ?? "").contains(key))
    }

    @Test("a model catalog entry offers its first model as the default")
    func defaultModel() {
        #expect(ModelCatalogProvider(id: "a", name: "A", models: ["m1", "m2"]).defaultModel == "m1")
        #expect(ModelCatalogProvider(id: "a", name: "A", models: []).defaultModel == nil)
    }
}

@Suite("Provider host check")
struct ProviderHostCheckTests {
    private func client(_ bots: ScriptedBots) -> ModelProvidersClient {
        ModelProvidersClient(gateway: bots.gateway, profile: "atlas")
    }

    @Test("the check decodes and its stages run in order")
    func stages() async throws {
        let bots = ScriptedBots()
        bots.script("model.providers.host_check", hostWire())
        guard case .checked(let check) = await client(bots).hostCheck("claude-subscription-directsdk-experimental") else {
            Issue.record("expected a check")
            return
        }
        #expect(check.cliVersion == "2.1.0" && check.plan == "Max" && check.pluginVersion == "0.3.0")
        #expect(check.installHint == "npm i -g claude" && check.disclosure == "Runs on this computer.")
        #expect(bots.calls(to: "model.providers.host_check").first?.params == ["provider": "claude-subscription-directsdk-experimental", "profile": "atlas"])

        let cases: [(JSONValue, ProviderHostCheck.Stage)] = [
            (hostWire(cli: false, signedIn: false, plugin: false), .cliMissing),
            (hostWire(cli: false, signedIn: true, plugin: true), .cliMissing),
            (hostWire(cli: true, signedIn: false, plugin: false), .notSignedIn),
            (hostWire(cli: true, signedIn: false, plugin: true), .notSignedIn),
            (hostWire(cli: true, signedIn: true, plugin: false), .pluginMissing),
            (hostWire(), .ready),
        ]
        for (wire, stage) in cases {
            #expect(try wire.decoded(as: ProviderHostCheck.self).stage == stage)
        }
    }

    @Test("missing fields mean not found and empty text is nothing")
    func sparse() throws {
        let check = try JSONValue.object(["plan": "", "install_hint": ""]).decoded(as: ProviderHostCheck.self)
        #expect(!check.cliFound && !check.signedIn && !check.pluginInstalled)
        #expect(check.plan == nil && check.installHint == nil && check.stage == .cliMissing)
    }

    @Test("a failed check says so in plain words")
    func failure() async {
        let broken = ScriptedBots()
        broken.script("model.providers.host_check") { _ in throw GatewayTransportError.closed(.normal) }
        #expect(await client(broken).hostCheck("x") == .failed(ModelProvidersClient.couldNotCheckHost))
        let garbled = ScriptedBots()
        garbled.script("model.providers.host_check", "nope")
        #expect(await client(garbled).hostCheck("x") == .failed(ModelProvidersClient.couldNotCheckHost))
    }

    @Test("install plugin maps installed, refused and everything else")
    func install() async {
        let row: JSONValue = ["id": "claude", "name": "Claude", "kind": "cli_plan", "state": "set"]
        let installed = ScriptedBots()
        installed.script("model.providers.install_plugin", ["outcome": "installed", "provider": row])
        guard case .installed(let provider?) = await client(installed).installPlugin("claude") else {
            Issue.record("expected the updated provider")
            return
        }
        #expect(provider.kind == .cliPlan && provider.state == .set)
        #expect(installed.calls(to: "model.providers.install_plugin").first?.params == ["provider": "claude", "profile": "atlas"])

        let expected: [(String, ProviderPluginInstall)] = [
            ("installed", .installed(nil)), ("refused", .refused("Not now.")), ("failed", .failed("Not now.")), ("surprise", .failed("Not now.")),
            ("already_installed", .installed(nil)),
        ]
        for (wire, result) in expected {
            let bots = ScriptedBots()
            bots.script("model.providers.install_plugin", ["outcome": .string(wire), "reason": "Not now."])
            #expect(await client(bots).installPlugin("claude") == result)
        }
        let broken = ScriptedBots()
        broken.script("model.providers.install_plugin") { _ in throw GatewayTransportError.closed(.normal) }
        #expect(await client(broken).installPlugin("claude") == .failed(ModelProvidersClient.couldNotInstallPlugin))
    }
}
