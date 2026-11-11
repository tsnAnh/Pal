import Foundation

public struct PendingAttachment: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case image
        case file
    }

    public enum Staged: Equatable, Sendable {
        case image(PromptAttachment)
        case file(referenceText: String)
    }

    public enum State: Equatable, Sendable {
        case uploading
        case ready(Staged)
        case failed(reason: String)
    }

    public let id: UUID
    public let kind: Kind
    public let name: String
    public let thumbnail: Data?
    public var state: State

    public init(id: UUID = UUID(), kind: Kind, name: String, thumbnail: Data?, state: State = .uploading) {
        self.id = id
        self.kind = kind
        self.name = name
        self.thumbnail = thumbnail
        self.state = state
    }

    public var failureReason: String? {
        if case .failed(let reason) = state { reason } else { nil }
    }
}

public struct PendingAttachments: Equatable, Sendable {
    public private(set) var items: [PendingAttachment] = []

    public init() {}

    public var isEmpty: Bool { items.isEmpty }

    public var readyToSend: [PendingAttachment.Staged] {
        items.compactMap { if case .ready(let staged) = $0.state { staged } else { nil } }
    }

    public mutating func append(_ attachment: PendingAttachment) {
        items.append(attachment)
    }

    public mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    public mutating func removeAll() {
        items.removeAll()
    }

    public mutating func setState(_ state: PendingAttachment.State, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = state
    }
}
