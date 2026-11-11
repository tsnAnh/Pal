import Foundation
import PalAuth
import PalProtocol

public enum ReachAttention: String, Sendable, Equatable {
    case foreground
    case background

    public init(sceneIsActive: Bool) {
        self = sceneIsActive ? .foreground : .background
    }
}

public enum ReachOutcome: String, Sendable, Equatable {
    case shown
    case acted
    case dismissed

    var isTerminal: Bool { self != .shown }
}

public enum ReachRole: Sendable, Equatable {
    case passive
    case offerTarget
    case deviceHost
}

public struct ReachOffer: Sendable, Equatable, Identifiable, Decodable {
    public enum Kind: String, Sendable, Decodable {
        case notify
        case suggest
    }

    public var offerID: String
    public var kind: Kind
    public var domain: String
    public var title: String
    public var body: String
    public var sessionID: String?

    public var id: String { offerID }

    public init(offerID: String, kind: Kind, domain: String, title: String, body: String, sessionID: String? = nil) {
        self.offerID = offerID
        self.kind = kind
        self.domain = domain
        self.title = title
        self.body = body
        self.sessionID = sessionID
    }

    enum CodingKeys: String, CodingKey {
        case offerID = "offer_id"
        case kind
        case domain
        case title
        case body
        case sessionID = "session_id"
    }

    public static let eventType = "reach.offer"

    public init?(event: GatewayEvent) {
        guard event.type == Self.eventType, let payload = event.payload,
              let decoded = try? payload.decoded(as: ReachOffer.self),
              !decoded.offerID.isEmpty, decoded.offerID.count <= 64
        else { return nil }
        self = decoded
    }
}

public enum ReachWire {
    public static let capability = "reach-v1"

    public static func helloParams(
        identity: DeviceIdentity,
        acceptsOffers: Bool,
        attention: ReachAttention,
        deviceTools: Bool = false,
        kind: String? = nil
    ) -> JSONValue {
        var params: [String: JSONValue] = [
            "kind": .string(kind ?? identity.kind),
            "device_id": .string(identity.deviceID),
            "label": .string(identity.label),
            "app_version": .string(identity.appVersion),
            "accepts_offers": .bool(acceptsOffers),
            "attention": .string(attention.rawValue),
        ]
        if !identity.model.isEmpty { params["model"] = .string(identity.model) }
        if !identity.os.isEmpty { params["os"] = .string(identity.os) }
        if deviceTools { params["device_tools"] = .bool(true) }
        return .object(params)
    }

    public static func attentionParams(_ attention: ReachAttention) -> JSONValue {
        ["state": .string(attention.rawValue)]
    }

    public static func outcomeParams(offerID: String, outcome: ReachOutcome) -> JSONValue {
        ["offer_id": .string(offerID), "outcome": .string(outcome.rawValue)]
    }
}

struct OfferLedger {
    private let capacity: Int
    private var order: [String] = []
    private var seen: Set<String> = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func admit(_ offerID: String) -> Bool {
        guard seen.insert(offerID).inserted else { return false }
        order.append(offerID)
        if order.count > capacity {
            seen.remove(order.removeFirst())
        }
        return true
    }
}
