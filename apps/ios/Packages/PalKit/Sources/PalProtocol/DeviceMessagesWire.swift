import Foundation

public struct MessageParticipantWire: Encodable, Sendable, Equatable {
    public var handle: String
    public var name: String?

    public init(handle: String, name: String?) {
        self.handle = handle
        self.name = name
    }
}

public struct MessageWire: Encodable, Sendable, Equatable {
    public var id: Int
    public var at: String
    public var fromMe: Bool
    public var sender: String?
    public var senderName: String?
    public var text: String
    public var service: String?

    public init(id: Int, at: String, fromMe: Bool, sender: String?, senderName: String?, text: String, service: String?) {
        self.id = id
        self.at = at
        self.fromMe = fromMe
        self.sender = sender
        self.senderName = senderName
        self.text = text
        self.service = service
    }
}

public struct ConversationWire: Encodable, Sendable, Equatable {
    public var chatId: String
    public var title: String?
    public var participants: [MessageParticipantWire]
    public var lastAt: String
    public var messages: [MessageWire]

    public init(chatId: String, title: String?, participants: [MessageParticipantWire], lastAt: String, messages: [MessageWire]) {
        self.chatId = chatId
        self.title = title
        self.participants = participants
        self.lastAt = lastAt
        self.messages = messages
    }
}

public struct MessagesRecentWire: Encodable, Sendable, Equatable {
    public var conversations: [ConversationWire]
    public var truncated: Bool

    public init(conversations: [ConversationWire], truncated: Bool) {
        self.conversations = conversations
        self.truncated = truncated
    }
}

public struct MessagesReadWire: Encodable, Sendable, Equatable {
    public var conversation: ConversationWire
    public var truncated: Bool

    public init(conversation: ConversationWire, truncated: Bool) {
        self.conversation = conversation
        self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey {
        case truncated
    }

    public func encode(to encoder: any Encoder) throws {
        try conversation.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(truncated, forKey: .truncated)
    }
}

public struct MessageMatchWire: Encodable, Sendable, Equatable {
    public var chatId: String
    public var title: String?
    public var message: MessageWire

    public init(chatId: String, title: String?, message: MessageWire) {
        self.chatId = chatId
        self.title = title
        self.message = message
    }
}

public struct MessagesSearchWire: Encodable, Sendable, Equatable {
    public var matches: [MessageMatchWire]
    public var truncated: Bool

    public init(matches: [MessageMatchWire], truncated: Bool) {
        self.matches = matches
        self.truncated = truncated
    }
}

public struct MessageSentWire: Encodable, Sendable, Equatable {
    public var sent: Bool
    public var service: String
    public var recipient: String

    public init(sent: Bool, service: String, recipient: String) {
        self.sent = sent
        self.service = service
        self.recipient = recipient
    }
}
