import SwiftUI

final class AvatarContentCache {
    private let store: AvatarContentStore
    private var spec: BotAvatarSpec?
    private var scheme: ColorScheme?
    private var eyeInk: AvatarColor?
    private var content: AvatarContent?

    init(store: AvatarContentStore = .shared) {
        self.store = store
    }

    var isSolid: Bool { content?.isSolid ?? false }

    func resolve(_ spec: BotAvatarSpec, _ scheme: ColorScheme, eyeInk: AvatarColor?) -> AvatarContent {
        if let content, self.spec == spec, self.scheme == scheme, self.eyeInk == eyeInk { return content }
        let built = store.content(for: spec, scheme: scheme, eyeInk: eyeInk)
        self.spec = spec
        self.scheme = scheme
        self.eyeInk = eyeInk
        content = built
        return built
    }
}
