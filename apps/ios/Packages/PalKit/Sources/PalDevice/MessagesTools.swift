import Foundation
import PalProtocol

public enum MessagesLimit {
    public static let text = 1000
    public static let participants = 20
    public static let query = 200
    public static let chatID = 200
    public static let recipient = 200
    public static let body = 4000
    public static let totalBytes = DeviceTextLimit.output
    static let messageOverhead = 200
}

public enum MessagesHint {
    public static let diskHint = "Messages. The owner must allow Pal under Full Disk Access in System Settings > Privacy & Security, then ask again"
    public static let automationHint = "Messages. The owner must allow Pal to control Messages under Automation in System Settings > Privacy & Security, then ask again"
}

enum MessagesToolHandler {
    static func run(_ action: DeviceToolAction, _ raw: JSONValue, provider: any MessagesProviding, zone: TimeZone) async throws -> JSONValue {
        do {
            return try await dispatch(action, raw, provider: provider, zone: zone)
        } catch DeviceProviderError.permissionDenied {
            throw DeviceProviderError.accessDenied(action == .messagesSend ? MessagesHint.automationHint : MessagesHint.diskHint)
        }
    }

    private static func dispatch(_ action: DeviceToolAction, _ raw: JSONValue, provider: any MessagesProviding, zone: TimeZone) async throws -> JSONValue {
        switch action {
        case .messagesRecent: try await recent(raw, provider, zone)
        case .messagesSearch: try await search(raw, provider, zone)
        case .messagesRead: try await read(raw, provider, zone)
        case .messagesSend: try await send(raw, provider)
        default: throw DeviceProviderError.unsupported
        }
    }

    private static func recent(_ raw: JSONValue, _ provider: any MessagesProviding, _ zone: TimeZone) async throws -> JSONValue {
        let args: MessagesRecentArgs = try DeviceWire.decodeArgs(raw)
        let record = try await provider.recent(
            limit: DeviceToolExecutor.clamp(args.limit, 10, 1...25), messagesPerChat: DeviceToolExecutor.clamp(args.messagesPerChat, 3, 1...10)
        )
        var budget = Budget(zone: zone)
        var conversations: [ConversationWire] = []
        for conversation in record.conversations {
            guard let wire = budget.conversation(conversation) else { break }
            conversations.append(wire)
            if budget.exhausted { break }
        }
        return try DeviceWire.encode(MessagesRecentWire(
            conversations: conversations, truncated: record.truncated || budget.exhausted || conversations.count < record.conversations.count
        ))
    }

    private static func search(_ raw: JSONValue, _ provider: any MessagesProviding, _ zone: TimeZone) async throws -> JSONValue {
        let args: MessagesSearchArgs = try DeviceWire.decodeArgs(raw)
        let query = try bounded(args.query, "query", MessagesLimit.query)
        let record = try await provider.search(query: query, limit: DeviceToolExecutor.clamp(args.limit, 10, 1...25))
        var budget = Budget(zone: zone)
        var matches: [MessageMatchWire] = []
        for match in record.matches {
            guard let message = budget.message(match.message) else { break }
            matches.append(MessageMatchWire(chatId: match.chatID, title: match.title, message: message))
        }
        return try DeviceWire.encode(MessagesSearchWire(matches: matches, truncated: record.truncated || matches.count < record.matches.count))
    }

    private static func read(_ raw: JSONValue, _ provider: any MessagesProviding, _ zone: TimeZone) async throws -> JSONValue {
        let args: MessagesReadArgs = try DeviceWire.decodeArgs(raw)
        guard (1...MessagesLimit.chatID).contains(args.chatId.count), !args.chatId.utf8.contains(0) else {
            throw DeviceProviderError.invalidArgs("chat_id must be 1 to \(MessagesLimit.chatID) characters.")
        }
        let record = try await provider.read(chatID: args.chatId, limit: DeviceToolExecutor.clamp(args.limit, 20, 1...50))
        var budget = Budget(zone: zone)
        let conversation = budget.conversation(record.conversation) ?? ConversationWire(
            chatId: record.conversation.chatID, title: record.conversation.title, participants: [],
            lastAt: ISODate.format(record.conversation.lastAt, in: zone), messages: []
        )
        return try DeviceWire.encode(MessagesReadWire(
            conversation: conversation, truncated: record.truncated || budget.exhausted
        ))
    }

    private static func send(_ raw: JSONValue, _ provider: any MessagesProviding) async throws -> JSONValue {
        let args: MessagesSendArgs = try DeviceWire.decodeArgs(raw)
        let recipient = try bounded(args.recipient, "recipient", MessagesLimit.recipient)
        guard !recipient.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw DeviceProviderError.invalidArgs("recipient must be a phone number or an email address.")
        }
        guard !args.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, args.text.count <= MessagesLimit.body, !args.text.utf8.contains(0) else {
            throw DeviceProviderError.invalidArgs("text must be 1 to \(MessagesLimit.body) characters.")
        }
        let service = try args.service.map { name -> MessageService in
            guard let value = MessageService(rawValue: name) else { throw DeviceProviderError.invalidArgs("service must be imessage or sms.") }
            return value
        }
        let record = try await provider.send(recipient: recipient, text: args.text, service: service)
        return try DeviceWire.encode(MessageSentWire(sent: true, service: record.service.rawValue, recipient: record.recipient))
    }

    private static func bounded(_ raw: String, _ field: String, _ maximum: Int) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= maximum, !value.utf8.contains(0) else {
            throw DeviceProviderError.invalidArgs("\(field) must be 1 to \(maximum) characters.")
        }
        return value
    }

    static func clip(_ text: String) -> String {
        let kept = String(text.prefix(MessagesLimit.text))
        let omitted = text.utf8.count - kept.utf8.count
        return TextCap.finish(CapturedText(text: kept, omittedBytes: omitted), limit: MessagesLimit.text * 4).text
    }

    private struct Budget {
        let zone: TimeZone
        var remaining = MessagesLimit.totalBytes
        var exhausted = false

        init(zone: TimeZone) {
            self.zone = zone
        }

        mutating func spend(_ bytes: Int) -> Bool {
            guard bytes <= remaining else {
                exhausted = true
                return false
            }
            remaining -= bytes
            return true
        }

        mutating func message(_ record: MessageRecord) -> MessageWire? {
            let text = MessagesToolHandler.clip(record.text)
            let cost = text.utf8.count + (record.sender?.utf8.count ?? 0) + (record.senderName?.utf8.count ?? 0) + MessagesLimit.messageOverhead
            guard spend(cost) else { return nil }
            return MessageWire(
                id: record.id, at: ISODate.format(record.at, in: zone), fromMe: record.fromMe, sender: record.sender,
                senderName: record.senderName, text: text, service: record.service
            )
        }

        mutating func conversation(_ record: ConversationRecord) -> ConversationWire? {
            let participants = record.participants.prefix(MessagesLimit.participants).map { MessageParticipantWire(handle: $0.handle, name: $0.name) }
            let header = participants.reduce(MessagesLimit.messageOverhead + record.chatID.utf8.count + (record.title?.utf8.count ?? 0)) {
                $0 + $1.handle.utf8.count + ($1.name?.utf8.count ?? 0) + 40
            }
            guard spend(header) else { return nil }
            var messages: [MessageWire] = []
            for item in record.messages {
                guard let wire = message(item) else { break }
                messages.append(wire)
            }
            return ConversationWire(
                chatId: record.chatID, title: record.title, participants: participants,
                lastAt: ISODate.format(record.lastAt, in: zone), messages: messages
            )
        }
    }
}
