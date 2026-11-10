import AppIntents
import Foundation

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .messages.conversationAttribute)
enum BotConversationAttribute: String, AppEnum {
    case unspecified

    static let caseDisplayRepresentations: [BotConversationAttribute: DisplayRepresentation] = [.unspecified: "Unspecified"]
}

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .messages.messageAttribute)
enum BotMessageAttribute: String, AppEnum {
    case unspecified

    static let caseDisplayRepresentations: [BotMessageAttribute: DisplayRepresentation] = [.unspecified: "Unspecified"]
}

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .messages.messageType)
enum BotMessageType: String, AppEnum {
    case unspecified

    static let caseDisplayRepresentations: [BotMessageType: DisplayRepresentation] = [
        .unspecified: "Message",
    ]
}

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .messages.messagePerson)
struct BotMessagePerson: AppEntity {
    static let defaultQuery = BotMessagePersonQuery()

    let id: String
    var person: IntentPerson

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }

    var displayName: String {
        if case .displayName(let name) = person.name { name } else { id }
    }

    init(bot: BotEntity) {
        id = bot.id
        person = IntentPerson(identifier: .applicationDefined(bot.id), name: .displayName(bot.name), handle: nil)
    }

    init(me name: String) {
        id = "me"
        person = IntentPerson(identifier: .applicationDefined("me"), name: .displayName(name), handle: nil, isMe: true)
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct BotMessagePersonQuery: EntityStringQuery {
    @Dependency var environment: IntentEnvironment

    func entities(for identifiers: [String]) async throws -> [BotMessagePerson] {
        let wanted = Set(identifiers)
        return try await environment.bots().filter { wanted.contains($0.id) }.map(BotMessagePerson.init)
    }

    func entities(matching string: String) async throws -> [BotMessagePerson] {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await environment.bots()
            .filter { needle.isEmpty || $0.name.localizedStandardContains(needle) || $0.id.localizedStandardContains(needle) }
            .map(BotMessagePerson.init)
    }

    func suggestedEntities() async throws -> [BotMessagePerson] {
        try await environment.bots().map(BotMessagePerson.init)
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .messages.conversation)
struct BotConversationEntity: AppEntity {
    static let defaultQuery = BotConversationQuery()

    let id: String
    var recipients: [BotMessagePerson]
    var displayName: String
    var previewText: AttributedString
    var conversationName: String?
    var isRead: Bool
    var attributes: Set<BotConversationAttribute>
    var dateLastActive: Date?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }

    init(bot: BotEntity) {
        id = bot.id
        recipients = [BotMessagePerson(bot: bot)]
        displayName = bot.name
        previewText = AttributedString()
        conversationName = nil
        isRead = true
        attributes = []
        dateLastActive = nil
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct BotConversationQuery: EntityStringQuery {
    @Dependency var environment: IntentEnvironment

    func entities(for identifiers: [String]) async throws -> [BotConversationEntity] {
        let wanted = Set(identifiers)
        return try await environment.bots().filter { wanted.contains($0.id) }.map(BotConversationEntity.init)
    }

    func entities(matching string: String) async throws -> [BotConversationEntity] {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await environment.bots()
            .filter { needle.isEmpty || $0.name.localizedStandardContains(needle) || $0.id.localizedStandardContains(needle) }
            .map(BotConversationEntity.init)
    }

    func suggestedEntities() async throws -> [BotConversationEntity] {
        try await environment.bots().map(BotConversationEntity.init)
    }
}
