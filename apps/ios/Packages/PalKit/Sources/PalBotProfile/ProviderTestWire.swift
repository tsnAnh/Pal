import Foundation
import PalProtocol

public enum ProviderTestFailureKind: Sendable, Equatable {
    case auth
    case network
    case timeout
    case model
    case quota
    case unsupported
    case other

    init(wire: String) {
        switch wire {
        case "auth": self = .auth
        case "network": self = .network
        case "timeout": self = .timeout
        case "model": self = .model
        case "quota": self = .quota
        case "unsupported": self = .unsupported
        default: self = .other
        }
    }
}

public struct ProviderTestError: Sendable, Equatable {
    public let code: String
    public let reason: String
    public let retryable: Bool
    public let kind: ProviderTestFailureKind

    public init(code: String, reason: String, retryable: Bool, kind: ProviderTestFailureKind) {
        self.code = code
        self.reason = reason
        self.retryable = retryable
        self.kind = kind
    }
}

public struct ProviderTestResult: Sendable, Equatable, Decodable {
    public let ok: Bool
    public let provider: String
    public let model: String
    public let latencyMilliseconds: Int
    public let replyPreview: String?
    public let error: ProviderTestError?

    public init(
        ok: Bool, provider: String, model: String, latencyMilliseconds: Int, replyPreview: String? = nil, error: ProviderTestError? = nil
    ) {
        self.ok = ok
        self.provider = provider
        self.model = model
        self.latencyMilliseconds = latencyMilliseconds
        self.replyPreview = replyPreview
        self.error = error
    }

    private struct ErrorWire: Decodable {
        let code: String?
        let reason: String?
        let retryable: Bool?
        let kind: String?
    }

    enum CodingKeys: String, CodingKey {
        case ok, provider, model, error
        case latencyMilliseconds = "latency_ms"
        case replyPreview = "reply_preview"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        if let whole = try? container.decodeIfPresent(Int.self, forKey: .latencyMilliseconds) {
            latencyMilliseconds = whole
        } else if let fraction = try? container.decodeIfPresent(Double.self, forKey: .latencyMilliseconds) {
            latencyMilliseconds = Int(fraction.rounded())
        } else {
            latencyMilliseconds = 0
        }
        replyPreview = try container.decodeIfPresent(String.self, forKey: .replyPreview).flatMap { $0.isEmpty ? nil : $0 }
        error = (try? container.decodeIfPresent(ErrorWire.self, forKey: .error)).map { wire in
            ProviderTestError(
                code: wire.code ?? "",
                reason: wire.reason.flatMap { $0.isEmpty ? nil : $0 } ?? ModelProvidersClient.testDidNotPass,
                retryable: wire.retryable ?? false,
                kind: ProviderTestFailureKind(wire: wire.kind ?? "")
            )
        }
    }

    static var couldNotRun: ProviderTestResult {
        ProviderTestResult(
            ok: false, provider: "", model: "", latencyMilliseconds: 0,
            error: ProviderTestError(code: "client_error", reason: ModelProvidersClient.couldNotTest, retryable: true, kind: .other))
    }
}

public struct ProviderTestRequest: Sendable, Equatable {
    public static let defaultTimeoutSeconds = 25
    public static let timeoutRange = 1...60

    public let provider: String
    public let model: String
    public let baseURL: String?
    public let apiKey: SecretString?
    public let timeoutSeconds: Int

    public init(
        provider: String, model: String, baseURL: String? = nil, apiKey: SecretString? = nil,
        timeoutSeconds: Int = ProviderTestRequest.defaultTimeoutSeconds
    ) {
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.timeoutSeconds = min(max(timeoutSeconds, Self.timeoutRange.lowerBound), Self.timeoutRange.upperBound)
    }

    var wireParams: [String: JSONValue] {
        var params: [String: JSONValue] = ["provider": .string(provider), "model": .string(model), "timeout_s": .int(timeoutSeconds)]
        if let baseURL, !baseURL.isEmpty { params["base_url"] = .string(baseURL) }
        if let apiKey, !apiKey.isEmpty { params["api_key"] = .string(apiKey.reveal()) }
        return params
    }
}

extension ModelProvidersClient {
    public func test(_ request: ProviderTestRequest) async -> ProviderTestResult {
        do {
            let result = try await gateway.call("model.providers.test", scoped(request.wireParams))
            return try gateway.decoded(ProviderTestResult.self, result)
        } catch {
            return .couldNotRun
        }
    }

    public func saveKey(_ provider: String, key: SecretString) async -> String? {
        do {
            _ = try await gateway.call("model.save_key", scoped(["slug": .string(provider), "api_key": .string(key.reveal())]))
            return nil
        } catch {
            if case .permissionDenied = BotsError.classify(error) { return Self.keyNeedsMainConnection }
            return Self.couldNotSaveKey
        }
    }

    static let couldNotTest = "Couldn't run the test. Try again in a moment."
    static let testDidNotPass = "The test didn't pass. Try again."
    static let couldNotSaveKey = "Couldn't save the key. Try again in a moment."
    static let keyNeedsMainConnection = "Only the main connection can save keys."
}
