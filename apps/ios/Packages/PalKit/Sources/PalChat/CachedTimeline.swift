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
    var lastSequence: Int?
    var replayEpoch: String?

    init(sessionID: String, entries: [TimelineEntryWire], older: OlderEdge, revision: String?, cursor: StreamCursor? = nil) {
        self.sessionID = sessionID
        self.entries = entries
        self.revision = revision
        lastSequence = cursor?.lastSequence
        replayEpoch = cursor?.replayEpoch
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

    var cursor: StreamCursor? {
        guard let lastSequence, let replayEpoch else { return nil }
        return StreamCursor(replayEpoch: replayEpoch, lastSequence: lastSequence)
    }

    func withCursor(_ cursor: StreamCursor?) -> CachedTimeline {
        var copy = self
        copy.lastSequence = cursor?.lastSequence
        copy.replayEpoch = cursor?.replayEpoch
        return copy
    }

    static func byteCost(_ entry: TimelineEntryWire) -> Int {
        (try? JSONEncoder().encode(entry).count) ?? entry.text.utf8.count + 256
    }
}
