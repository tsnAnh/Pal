import Foundation

public enum ServiceSignInReason: String, Sendable, Hashable {
    case missing
    case expired
    case revoked
    case unknown

    public init(wire raw: String?) {
        self = raw.flatMap(Self.init(rawValue:)) ?? .unknown
    }
}

public enum ServiceSignInFlow: String, Sendable, Hashable, CaseIterable {
    case deviceCode = "device_code"
    case oauth
    case oauthPaste = "oauth_paste"
    case apiKey = "api_key"
    case header
    case manual
    case unknown

    public init(wire raw: String?) {
        self = raw.flatMap(Self.init(rawValue:)) ?? .unknown
    }
}

public enum ServiceSignInOutcome: String, Sendable, Hashable {
    case signedIn = "signed_in"
    case failed
    case declined
    case timedOut = "timed_out"
    case unknown

    public init(wire raw: String?) {
        self = raw.flatMap(Self.init(rawValue:)) ?? .unknown
    }
}

public struct AuthRequiredEvent: Sendable, Hashable {
    public static let eventType = "auth.required"

    public var requestID: String
    public var service: String
    public var serviceName: String
    public var bot: String
    public var bots: [String]
    public var reason: ServiceSignInReason
    public var flow: ServiceSignInFlow
    public var userCode: String?
    public var verificationURI: String?
    public var expiresIn: Int?
    public var server: String?

    public init(
        requestID: String,
        service: String,
        serviceName: String,
        bot: String,
        bots: [String],
        reason: ServiceSignInReason,
        flow: ServiceSignInFlow,
        userCode: String? = nil,
        verificationURI: String? = nil,
        expiresIn: Int? = nil,
        server: String? = nil
    ) {
        self.requestID = requestID
        self.service = service
        self.serviceName = serviceName
        self.bot = bot
        self.bots = bots
        self.reason = reason
        self.flow = flow
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.expiresIn = expiresIn
        self.server = server
    }

    public init?(event: GatewayEvent) {
        guard event.type == Self.eventType, let payload = event.payload,
              let requestID = payload["request_id"]?.stringValue, !requestID.isEmpty,
              let service = payload["service"]?.stringValue, !service.isEmpty
        else { return nil }
        let bot = payload["bot"]?.stringValue ?? ""
        var bots = (payload["bots"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.isEmpty }
        if !bot.isEmpty, !bots.contains(bot) { bots.insert(bot, at: 0) }
        var seen = Set<String>()
        bots = bots.filter { seen.insert($0).inserted }
        let name = payload["service_name"]?.stringValue ?? ""
        self.init(
            requestID: requestID,
            service: service,
            serviceName: name.isEmpty ? service : name,
            bot: bot.isEmpty ? (bots.first ?? "") : bot,
            bots: bots,
            reason: ServiceSignInReason(wire: payload["reason"]?.stringValue),
            flow: ServiceSignInFlow(wire: payload["flow"]?.stringValue),
            userCode: payload["user_code"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
            verificationURI: payload["verification_uri"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
            expiresIn: payload["expires_in"]?.intValue,
            server: payload["server"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

public struct AuthResolvedEvent: Sendable, Hashable {
    public static let eventType = "auth.resolved"

    public var requestID: String
    public var outcome: ServiceSignInOutcome
    public var reason: String?

    public init(requestID: String, outcome: ServiceSignInOutcome, reason: String? = nil) {
        self.requestID = requestID
        self.outcome = outcome
        self.reason = reason
    }

    public init?(event: GatewayEvent) {
        guard event.type == Self.eventType, let payload = event.payload,
              let requestID = payload["request_id"]?.stringValue, !requestID.isEmpty
        else { return nil }
        self.init(
            requestID: requestID,
            outcome: ServiceSignInOutcome(wire: payload["outcome"]?.stringValue),
            reason: payload["reason"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

public struct AuthSignInResult: Sendable, Hashable {
    public var recorded: Bool
    public var authorizationURL: String?

    public init(recorded: Bool, authorizationURL: String? = nil) {
        self.recorded = recorded
        self.authorizationURL = authorizationURL
    }

    public init(_ value: JSONValue) {
        recorded = value["recorded"]?.boolValue ?? false
        authorizationURL = value["authorization_url"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }
}

public enum AuthCredentialOutcome: String, Sendable, Hashable {
    case stored = "stored"
    case failed = "failed"
    case rejected = "rejected"
    case unknown = "unknown"

    public init(wire raw: String?) {
        self = raw.flatMap(Self.init(rawValue:)) ?? .unknown
    }

    public init(_ result: JSONValue) {
        self.init(wire: result["outcome"]?.stringValue)
    }
}

public struct AuthCallbackResult: Sendable, Hashable {
    public var outcome: AuthCredentialOutcome
    public var reason: String?

    public init(outcome: AuthCredentialOutcome, reason: String? = nil) {
        self.outcome = outcome
        self.reason = reason
    }

    public init(_ value: JSONValue) {
        outcome = AuthCredentialOutcome(value)
        reason = value["reason"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }
}

public enum ServiceSignInWire {
    public static let signInMethod = "auth.signin"
    public static let declineMethod = "auth.decline"
    public static let submitCredentialMethod = "auth.submit_credential"
    public static let submitCallbackMethod = "auth.submit_callback"
    public static let beginMethod = "auth.begin"

    public static func requestParams(_ requestID: String) -> JSONValue {
        ["request_id": .string(requestID)]
    }

    public static func submitCallbackParams(requestID: String, value: String) -> JSONValue {
        ["request_id": .string(requestID), "value": .string(value)]
    }

    public static func submitCredentialParams(requestID: String, value: SecretString) -> JSONValue {
        ["request_id": .string(requestID), "value": .string(value.reveal())]
    }
}
