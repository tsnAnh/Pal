import AppIntents
import Foundation
import GeoToolbox
import PalChat

@available(iOS 27.0, macOS 27.0, *)
@UnionValue
enum BotMessageDestination {
    case people([IntentPerson])
    case messagePerson(BotMessagePerson)
    case messagePeople([BotMessagePerson])

    func bot() throws -> BotEntity {
        switch self {
        case .messagePerson(let person):
            return BotEntity(id: person.id, name: person.displayName, isDefault: false)
        case .messagePeople(let people) where people.count == 1:
            return BotEntity(id: people[0].id, name: people[0].displayName, isDefault: false)
        case .messagePeople:
            throw BotIntentError.oneBotAtATime
        case .people:
            throw BotIntentError.unknownBot
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct BotMessageContent {
    let text: String
    let files: [OutgoingFile]

    init(
        content: AttributedString?,
        subject: AttributedString?,
        attachments: [IntentFile],
        audioMessage: IntentFile?,
        locations: [PlaceDescriptor],
        links: [URL],
        scheduledDate: Date?,
        allowsFiles: Bool = true
    ) throws {
        guard subject == nil, audioMessage == nil, locations.isEmpty, scheduledDate == nil else {
            throw BotIntentError.unsupportedMessage
        }
        guard allowsFiles || attachments.isEmpty else { throw BotIntentError.draftHasNoFiles }
        let body = content.map { String($0.characters).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        text = ([body] + links.map(\.absoluteString)).filter { !$0.isEmpty }.joined(separator: "\n")
        files = try IntentAttachments.files(from: attachments)
    }
}
