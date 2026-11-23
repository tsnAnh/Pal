import Foundation

public struct ConversationMedia: Sendable, Hashable, Identifiable {
    public let id: String
    public let reference: MediaReference
}

public struct ConversationMediaRow: Sendable, Equatable {
    public let rowID: String
    public let media: [MediaReference]

    public init(rowID: String, media: [MediaReference]) {
        self.rowID = rowID
        self.media = media
    }
}

public enum ConversationMediaList {
    public static func list(from rows: [ConversationMediaRow]) -> [ConversationMedia] {
        rows.flatMap { row in
            row.media.filter { $0.kind == .video }.map { ConversationMedia(id: itemID(rowID: row.rowID, media: $0), reference: $0) }
        }
    }

    public static func itemID(rowID: String, media: MediaReference) -> String {
        "\(rowID)/\(media.id)"
    }

    public static func viewer(opening media: MediaReference, inRow rowID: String, rows: [ConversationMediaRow]) -> MediaViewerState? {
        MediaViewerState(items: list(from: rows), opening: itemID(rowID: rowID, media: media), anchorRowID: rowID)
    }
}

public struct MediaViewerState: Sendable, Equatable {
    public let items: [ConversationMedia]
    public private(set) var index: Int
    public let anchorRowID: String
    public private(set) var files: [String: URL] = [:]

    public init?(items: [ConversationMedia], opening id: String, anchorRowID: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        self.items = items
        self.index = index
        self.anchorRowID = anchorRowID
    }

    public var current: ConversationMedia { items[index] }
    public var title: String { current.reference.name }
    public var canGoPrevious: Bool { index > 0 }
    public var canGoNext: Bool { index < items.count - 1 }
    public var showsStepper: Bool { items.count > 1 }

    public var positionLabel: String? {
        showsStepper ? String(localized: "\(index + 1) of \(items.count)") : nil
    }

    public mutating func goPrevious() {
        if canGoPrevious { index -= 1 }
    }

    public mutating func goNext() {
        if canGoNext { index += 1 }
    }

    public func file(for id: String) -> URL? { files[id] }

    public mutating func record(_ file: URL, for id: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        files[id] = file
    }

    public static func close(_ state: inout MediaViewerState?) -> [URL] {
        let leftovers = state.map { Array($0.files.values) } ?? []
        state = nil
        return leftovers
    }
}
