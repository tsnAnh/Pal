import Foundation
import PalProtocol

public struct CachedTimeline: Codable, Sendable, Equatable {
    public static let maxEntries = 200
    public static let maxBytes = 1_000_000
    public static let namePrefix = "timeline-"

    public static func cacheName(forBot name: String) -> String { namePrefix + name }

    public var sessionID: String
    var entries: [TimelineEntryWire]
    var olderCursor: String?
    var reachesStart: Bool
    var revision: String?

    init(sessionID: String, entries: [TimelineEntryWire], older: OlderEdge, revision: String?) {
        self.sessionID = sessionID
        self.entries = entries
        self.revision = revision
        switch older {
        case .more(let cursor), .loading(let cursor), .failed(let cursor, _, _):
            olderCursor = cursor
            reachesStart = false
        case .start:
            olderCursor = nil
            reachesStart = true
        case .unknown:
            olderCursor = nil
            reachesStart = false
        }
    }

    var olderEdge: OlderEdge {
        if let olderCursor { return .more(olderCursor) }
        return reachesStart ? .start : .unknown
    }

    public var entryCount: Int { entries.count }

    static func byteCost(_ entry: TimelineEntryWire) -> Int {
        (try? JSONEncoder().encode(entry).count) ?? entry.text.utf8.count + 256
    }
}
