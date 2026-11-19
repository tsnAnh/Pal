import Foundation

public struct ConversationImage: Sendable, Hashable, Identifiable {
    public let id: String
    public let reference: ImageReference
    public let messageText: String?
}

public enum ConversationImages {
    public struct Row: Sendable {
        public let rowID: String
        public let text: String?
        public let images: [ImageReference]

        public init(rowID: String, text: String?, images: [ImageReference]) {
            self.rowID = rowID
            self.text = text
            self.images = images
        }
    }

    public static func list(from rows: [(rowID: String, images: [ImageReference])]) -> [ConversationImage] {
        list(from: rows.map { Row(rowID: $0.rowID, text: nil, images: $0.images) })
    }

    public static func list(from rows: [Row]) -> [ConversationImage] {
        rows.flatMap { row in
            row.images.filter(isLoadable).map {
                ConversationImage(id: "\(row.rowID)/\($0.id)", reference: $0, messageText: row.text)
            }
        }
    }

    static func isLoadable(_ reference: ImageReference) -> Bool {
        switch reference.source {
        case .hostPath(let path): !path.trimmingCharacters(in: .whitespaces).isEmpty
        case .remote(let url): url.scheme?.lowercased() == "https"
        case .inline(let data): !data.isEmpty
        }
    }
}

public struct ViewerStaging: Sendable, Equatable {
    public let imageID: String
    public let task: Task<UUID?, Never>
    public fileprivate(set) var attachmentID: UUID?

    public init(imageID: String, task: Task<UUID?, Never>) {
        self.imageID = imageID
        self.task = task
    }
}

public struct ImageViewerState: Sendable, Equatable {
    public let images: [ConversationImage]
    public private(set) var index: Int
    public let anchorRowID: String
    public private(set) var staging: ViewerStaging?

    public init?(images: [ConversationImage], opening id: String, anchorRowID: String) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return nil }
        self.images = images
        self.index = index
        self.anchorRowID = anchorRowID
    }

    public var current: ConversationImage { images[index] }
    public var canGoPrevious: Bool { index > 0 }
    public var canGoNext: Bool { index < images.count - 1 }

    public mutating func goPrevious() {
        if canGoPrevious { index -= 1 }
    }

    public mutating func goNext() {
        if canGoNext { index += 1 }
    }

    public mutating func beginStaging(_ staging: ViewerStaging) {
        self.staging = staging
    }

    public mutating func recordStaged(_ attachmentID: UUID, for imageID: String) {
        guard staging?.imageID == imageID else { return }
        staging?.attachmentID = attachmentID
    }

    public mutating func clearStaging() {
        staging = nil
    }
}
