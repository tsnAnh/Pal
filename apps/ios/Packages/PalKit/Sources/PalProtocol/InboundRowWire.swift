public protocol InboundRowWire {
    var displayKind: String? { get }
    var displayMetadata: JSONValue? { get }
}

public extension InboundRowWire {
    var displayMetadata: JSONValue? { nil }

    var submissionID: String? {
        displayMetadata?["submission_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }
}
