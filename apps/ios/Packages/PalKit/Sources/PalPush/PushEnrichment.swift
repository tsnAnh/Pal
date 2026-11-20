import Foundation

public struct PushEnrichment: Equatable, Sendable {
    public let sender: PushSender
    public let avatar: Data

    public init?(userInfo: [AnyHashable: Any], title: String, body: String, cache: PushAvatarCache?) {
        guard let cache,
              let sender = PushSender(userInfo: userInfo, title: title, body: body),
              let avatar = cache.image(for: sender.profile)
        else { return nil }
        self.sender = sender
        self.avatar = avatar
    }
}
