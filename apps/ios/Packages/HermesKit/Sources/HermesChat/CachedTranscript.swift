import Foundation

public struct CachedTranscriptItem: Codable, Sendable, Equatable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    var id: String
    var uid: String?
    var role: Role
    var text: String
    var timestamp: Date?
    var inboundKind: String
    var senderName: String?
    var senderHandle: String?
    var body: String?

    init?(_ item: TranscriptItem, date: Date?) {
        id = item.id
        uid = item.uid
        timestamp = date
        switch item.content {
        case .user(let text, let delivery):
            guard delivery == .sent, item.deliveryFailure == nil else { return nil }
            role = .user
            self.text = text
        case .assistant(let text, _, let streaming):
            guard !streaming, !text.isEmpty else { return nil }
            role = .assistant
            self.text = text
        default:
            return nil
        }
        switch item.inbound {
        case .person:
            inboundKind = "person"
        case .botMessage(let sender, let body):
            inboundKind = "bot"
            senderName = sender.name
            senderHandle = sender.handle
            self.body = body
        case .systemNotification:
            inboundKind = "system"
        case .processCompletion:
            inboundKind = "process"
        }
    }

    var inbound: InboundKind {
        switch inboundKind {
        case "bot":
            if let senderName, let senderHandle, let body {
                .botMessage(BotSender(name: senderName, handle: senderHandle), body: body)
            } else {
                .person
            }
        case "system": .systemNotification
        case "process": .processCompletion
        default: .person
        }
    }

    var transcriptItem: TranscriptItem {
        let content: TranscriptItem.Content = switch role {
        case .user: .user(text: text, delivery: .sent)
        case .assistant: .assistant(text: text, reasoning: "", isStreaming: false)
        }
        return TranscriptItem(id: id, content: content, timestamp: timestamp, inbound: role == .user ? inbound : .person, uid: uid)
    }

    var byteCost: Int {
        text.utf8.count + (body?.utf8.count ?? 0) + id.utf8.count + 96
    }
}

public struct CachedTranscript: Codable, Sendable, Equatable {
    public static let maxItems = 200
    public static let maxBytes = 1_000_000
    public static let namePrefix = "chat-"

    public static func cacheName(forBot name: String) -> String { namePrefix + name }

    public var sessionID: String
    var items: [CachedTranscriptItem]

    public init?(
        sessionID: String?,
        items source: [TranscriptItem],
        date: (TranscriptItem) -> Date?,
        maxItems: Int = CachedTranscript.maxItems,
        maxBytes: Int = CachedTranscript.maxBytes
    ) {
        guard let sessionID, !sessionID.isEmpty else { return nil }
        var kept: [CachedTranscriptItem] = []
        var budget = maxBytes
        for item in source.reversed() {
            guard let cached = CachedTranscriptItem(item, date: item.timestamp ?? date(item)) else { continue }
            guard kept.count < maxItems, cached.byteCost <= budget else { break }
            budget -= cached.byteCost
            kept.append(cached)
        }
        guard !kept.isEmpty else { return nil }
        self.sessionID = sessionID
        items = kept.reversed()
    }

    public var transcriptItems: [TranscriptItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }.map(\.transcriptItem)
    }
}
