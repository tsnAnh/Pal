#if os(macOS)
import Foundation
import PalBotProfile
import PalProtocol
import PalTransport

enum ProviderOnboardingScript {
    static let argument = "-hermes-test-provider-onboarding"
    static let claudeMissingArgument = "-hermes-test-provider-onboarding-claude-missing"
    static let wrongKey = "sk-test-wrong-0001"
    static let rightKey = "sk-test-right-0001"
    static let slowKey = "sk-test-slow-0001"
    static let offlineKey = "sk-test-offline-0001"
    static let wrongKeyReason = "The key was rejected. Check it and try again."
    static let offlineReason = "Couldn't reach the provider."
    static let latencyMilliseconds = 1400
    static let slowReplyDelay = Duration.milliseconds(11_500)

    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    static func gateway() -> BotsGateway {
        let script = ScriptedProviderGateway(claudeMissing: ProcessInfo.processInfo.arguments.contains(claudeMissingArgument))
        return BotsGateway { method, params in try await script.call(method, params ?? [:]) }
    }
}

actor ScriptedProviderGateway {
    private struct Row {
        let id: String
        let name: String
        let kind: String
        var state = "not_set"
        var baseURL: String?
        var defaultBaseURL: String?

        var json: JSONValue {
            [
                "id": .string(id), "name": .string(name), "kind": .string(kind), "state": .string(state), "scope": "profile",
                "base_url_editable": .bool(defaultBaseURL != nil), "base_url": baseURL.map(JSONValue.string) ?? .null,
                "default_base_url": defaultBaseURL.map(JSONValue.string) ?? .null, "can_remove": .bool(state == "set"),
            ]
        }
    }

    private static let models: [JSONValue] = ["scripted-model-fast", "scripted-model-large"]

    private var rows = [
        Row(id: "claude-subscription-directsdk-experimental", name: "Claude Direct SDK", kind: "cli_plan"),
        Row(id: "openai-codex", name: "OpenAI Codex", kind: "device_code"),
        Row(id: "nous", name: "Nous Portal", kind: "oauth_paste"),
        Row(id: "anthropic", name: "Anthropic", kind: "api_key"),
        Row(id: "openrouter", name: "OpenRouter", kind: "api_key"),
        Row(id: "gemini", name: "Google Gemini", kind: "api_key"),
        Row(id: "deepseek", name: "DeepSeek", kind: "api_key"),
        Row(id: "lmstudio", name: "LM Studio", kind: "api_key", defaultBaseURL: "http://localhost:1234/v1"),
    ]
    private var pluginInstalled = false
    private let claudeMissing: Bool

    init(claudeMissing: Bool) {
        self.claudeMissing = claudeMissing
    }

    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        switch method {
        case "model.providers.list": return ["providers": .array(rows.map(\.json))]
        case "model.providers.host_check": return hostCheck()
        case "model.providers.install_plugin": return installPlugin(params)
        case "model.providers.test": return try await test(params)
        case "model.options": return options()
        case "model.save_key": return saveKey(params)
        case "model.providers.set_base_url": return setBaseURL(params)
        case "model.providers.remove": return remove(params)
        case "profiles.configure": return ["applied": ["model": true]]
        default: throw GatewayTransportError.rpc(RPCError(code: 4041, message: "unscripted", data: ["reason": .string("unscripted")]))
        }
    }

    private func hostCheck() -> JSONValue {
        guard !claudeMissing else {
            return [
                "cli_found": false, "signed_in": false, "plugin_installed": false,
                "install_hint": "Install Claude Code, run claude once to sign in, then check again.",
            ]
        }
        return [
            "cli_found": true, "cli_version": "2.0.0", "signed_in": true, "plan": "Max", "plugin_installed": .bool(pluginInstalled),
        ]
    }

    private func installPlugin(_ params: JSONValue) -> JSONValue {
        guard !claudeMissing else { return ["outcome": "refused", "reason": "Claude Code is not installed on this Mac."] }
        pluginInstalled = true
        return action("installed", provider: params["provider"]?.stringValue)
    }

    private func options() -> JSONValue {
        let providers = rows.map { row -> JSONValue in
            ["slug": .string(row.id), "name": .string(row.name), "models": .array(Self.models), "authenticated": .bool(row.state == "set")]
        }
        return ["providers": .array(providers)]
    }

    private func saveKey(_ params: JSONValue) -> JSONValue {
        update(params["slug"]?.stringValue) { $0.state = "set" }
        return ["ok": true]
    }

    private func setBaseURL(_ params: JSONValue) -> JSONValue {
        let address = params["base_url"]?.stringValue
        let id = params["provider"]?.stringValue
        update(id) { $0.baseURL = address }
        return action(address == nil ? "reset" : "saved", provider: id)
    }

    private func remove(_ params: JSONValue) -> JSONValue {
        let id = params["provider"]?.stringValue
        update(id) {
            $0.state = "not_set"
            $0.baseURL = nil
        }
        return action("removed", provider: id)
    }

    private func test(_ params: JSONValue) async throws -> JSONValue {
        let provider = params["provider"]?.stringValue ?? ""
        let model = params["model"]?.stringValue ?? ""
        switch params["api_key"]?.stringValue ?? "" {
        case ProviderOnboardingScript.wrongKey:
            return failure(provider, model, error: error("auth_failed", ProviderOnboardingScript.wrongKeyReason, kind: "auth", retryable: false))
        case ProviderOnboardingScript.offlineKey:
            return failure(provider, model, error: error("network_unreachable", ProviderOnboardingScript.offlineReason, kind: "network", retryable: true))
        case ProviderOnboardingScript.slowKey:
            try await Task.sleep(for: ProviderOnboardingScript.slowReplyDelay)
            return success(provider, model)
        default:
            return success(provider, model)
        }
    }

    private func success(_ provider: String, _ model: String) -> JSONValue {
        [
            "ok": true, "provider": .string(provider), "model": .string(model),
            "latency_ms": .int(ProviderOnboardingScript.latencyMilliseconds), "reply_preview": "OK",
        ]
    }

    private func error(_ code: String, _ reason: String, kind: String, retryable: Bool) -> JSONValue {
        ["code": .string(code), "reason": .string(reason), "retryable": .bool(retryable), "kind": .string(kind)]
    }

    private func failure(_ provider: String, _ model: String, error: JSONValue) -> JSONValue {
        ["ok": false, "provider": .string(provider), "model": .string(model), "latency_ms": 0, "error": error]
    }

    private func action(_ outcome: String, provider id: String?) -> JSONValue {
        let row = rows.first { $0.id == id }
        return ["outcome": .string(outcome), "provider": row?.json ?? .null]
    }

    private func update(_ id: String?, _ change: (inout Row) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[index])
    }
}
#endif
