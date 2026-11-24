import Foundation

public struct DraftAttachment: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case image, file }

    public let id: UUID
    public let kind: Kind
    public let name: String
    public let mime: String
    public let stored: String
    public let thumbnail: String?

    public init(id: UUID, kind: Kind, name: String, mime: String, stored: String, thumbnail: String?) {
        self.id = id
        self.kind = kind
        self.name = name
        self.mime = mime
        self.stored = stored
        self.thumbnail = thumbnail
    }
}

public struct ComposerDraft: Codable, Sendable, Equatable {
    public var text: String
    public var attachments: [DraftAttachment]

    public init(text: String = "", attachments: [DraftAttachment] = []) {
        self.text = text
        self.attachments = attachments
    }

    public static let empty = ComposerDraft()

    public var isEmpty: Bool {
        attachments.isEmpty && text.allSatisfy(\.isWhitespace)
    }
}
