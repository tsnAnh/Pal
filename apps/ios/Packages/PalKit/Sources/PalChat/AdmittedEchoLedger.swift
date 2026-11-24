import Foundation

public struct AdmittedEchoLedger: Sendable, Equatable {
    public struct Resolution: Sendable, Equatable {
        public var unechoed: [OutboxEntry]
        public var echoes: [String: String]
    }

    public static let clockSkew: TimeInterval = 120
    public static let recentItems = 40
    public static let retention: TimeInterval = 600

    private var claims: [String: Set<String>] = [:]

    public init() {}

    public static func rowID(of entry: OutboxEntry) -> String { Transcript.echoID(entry.submissionID) }

    public mutating func resolve(
        entries: [OutboxEntry],
        text: (OutboxEntry) -> String,
        timeline items: [TranscriptItem]
    ) -> Resolution {
        let present = Set(items.map(\.id))
        claims = claims.filter { present.contains($0.key) }
        let recent = Set(items.suffix(Self.recentItems).map(\.id))
        var resolution = Resolution(unechoed: [], echoes: [:])
        for entry in entries where entry.state.isAdmitted {
            switch echo(of: entry, text: text(entry), items: items, recent: recent) {
            case .confirmed(let id): resolution.echoes[entry.submissionID] = id
            case .local: break
            case .missing: resolution.unechoed.append(entry)
            }
        }
        return resolution
    }

    private enum Echo {
        case confirmed(String)
        case local
        case missing
    }

    private mutating func echo(of entry: OutboxEntry, text: String, items: [TranscriptItem], recent: Set<String>) -> Echo {
        let own = Self.rowID(of: entry)
        if let item = items.first(where: { $0.id == own }) {
            if case .user(_, let delivery) = item.content, delivery != .sending { return .confirmed(own) }
            return .local
        }
        if let held = claims.first(where: { $0.value.contains(entry.submissionID) })?.key { return .confirmed(held) }
        guard !text.isEmpty else { return .missing }
        for item in items {
            guard let itemText = Self.personText(of: item), !item.id.hasPrefix("submission:"),
                  Self.isWithinBounds(item, of: entry, recent: recent)
            else { continue }
            let combined = item.id.hasPrefix(Transcript.absorbedPrefix) && itemText != text && itemText.contains(text)
            let exact = itemText == text && claims[item.id] == nil
            guard exact || combined else { continue }
            claims[item.id, default: []].insert(entry.submissionID)
            return .confirmed(item.id)
        }
        return .missing
    }

    private static func personText(of item: TranscriptItem) -> String? {
        guard item.inbound.isPerson, case .user(let text, _) = item.content else { return nil }
        return text
    }

    private static func isWithinBounds(_ item: TranscriptItem, of entry: OutboxEntry, recent: Set<String>) -> Bool {
        guard let timestamp = item.timestamp else { return recent.contains(item.id) }
        return timestamp >= entry.createdAt.addingTimeInterval(-clockSkew)
    }
}
