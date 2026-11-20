import Intents
import PalPush
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let content = request.content
        guard let enrichment = PushEnrichment(
            userInfo: content.userInfo, title: content.title, body: content.body, cache: .shared()
        ) else {
            contentHandler(content)
            return
        }
        contentHandler(Self.communication(content, from: enrichment) ?? content)
    }

    override func serviceExtensionTimeWillExpire() {}

    private static func communication(_ content: UNNotificationContent, from enrichment: PushEnrichment) -> UNNotificationContent? {
        let sender = enrichment.sender
        let person = INPerson(
            personHandle: INPersonHandle(value: sender.profile, type: .unknown),
            nameComponents: nil,
            displayName: sender.displayName,
            image: INImage(imageData: enrichment.avatar),
            contactIdentifier: nil,
            customIdentifier: sender.profile
        )
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: sender.body,
            speakableGroupName: nil,
            conversationIdentifier: sender.profile,
            serviceName: nil,
            sender: person,
            attachments: nil
        )
        return try? content.updating(from: intent)
    }
}
