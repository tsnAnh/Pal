import Foundation

public struct ConversationImage: Sendable, Hashable, Identifiable {
    public let id: String
    public let reference: ImageReference
}

public enum ConversationImages {
    public static func list(from rows: [(rowID: String, images: [ImageReference])]) -> [ConversationImage] {
        rows.flatMap { row in
            row.images.filter(isLoadable).map { ConversationImage(id: "\(row.rowID)/\($0.id)", reference: $0) }
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

public struct ImageViewerState: Sendable, Equatable {
    public let images: [ConversationImage]
    public private(set) var index: Int
    public let anchorRowID: String

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
}
