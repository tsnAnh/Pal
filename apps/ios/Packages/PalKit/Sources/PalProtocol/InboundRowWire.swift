public protocol InboundRowWire {
    var displayKind: String? { get }
    var displayMetadata: JSONValue? { get }
}

public extension InboundRowWire {
    var displayMetadata: JSONValue? { nil }
}
