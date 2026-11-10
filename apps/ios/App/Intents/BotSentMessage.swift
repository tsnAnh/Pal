import AppIntents
import Foundation
import GeoToolbox
import LinkPresentation

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .messages.messageEffect)
enum BotMessageEffect: String, AppEnum {
    case unspecified

    static let caseDisplayRepresentations: [BotMessageEffect: DisplayRepresentation] = [.unspecified: "Unspecified"]
}

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .messages.customReaction)
enum BotCustomReaction: String, AppEnum {
    case unspecified

    static let caseDisplayRepresentations: [BotCustomReaction: DisplayRepresentation] = [.unspecified: "Unspecified"]
}

@available(iOS 27.0, macOS 27.0, *)
@UnionValue
enum BotReadReaction {
    case customReaction(BotCustomReaction)
    case attributedString(AttributedString)
}

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .messages.customAttachment)
struct BotCustomAttachment: AppEntity {
    static let defaultQuery = BotCustomAttachmentQuery()

    let id: String
    var sourceName: AttributedString?
    var description: AttributedString?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Attachment")
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct BotCustomAttachmentQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [BotCustomAttachment] { [] }
}

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .messages.message)
struct BotSentMessage: AppEntity {
    static let defaultQuery = BotSentMessageQuery()

    let id: String
    var messageType: BotMessageType
    var author: BotMessagePerson
    var isRead: Bool
    var attributes: Set<BotMessageAttribute>
    var conversation: BotConversationEntity
    var date: Date
    var subject: AttributedString?
    var body: AttributedString?
    var attachments: [IntentFile]
    var audioMessage: IntentFile?
    var customAttachments: [BotCustomAttachment]
    var locations: [PlaceDescriptor]
    var links: [LinkMetadata]
    var messageEffect: BotMessageEffect?
    var reaction: BotReadReaction?
    var notificationIdentifier: String?
    var referencedMessage: BotSentMessage? { nil }

    init(submissionID: String, text: String, to bot: BotEntity, at date: Date, attachments: [IntentFile] = []) {
        id = submissionID
        messageType = .unspecified
        author = BotMessagePerson(me: String(localized: "You"))
        isRead = true
        attributes = []
        conversation = BotConversationEntity(bot: bot)
        self.date = date
        subject = nil
        body = AttributedString(text)
        self.attachments = attachments
        audioMessage = nil
        customAttachments = []
        locations = []
        links = []
        messageEffect = nil
        reaction = nil
        notificationIdentifier = nil
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(String(body.map { String($0.characters) } ?? ""))")
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct BotSentMessageQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [BotSentMessage] { [] }
}
