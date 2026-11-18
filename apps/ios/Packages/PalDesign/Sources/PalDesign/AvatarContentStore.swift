import Foundation
import SwiftUI

final class AvatarContentStore: @unchecked Sendable {
    static let shared = AvatarContentStore()
    static let capacity = 64

    private struct Entry {
        let spec: BotAvatarSpec
        let scheme: ColorScheme
        let eyeInk: AvatarColor?
        let content: AvatarContent
    }

    private let lock = NSLock()
    private let build: (BotAvatarSpec, ColorScheme, AvatarColor?) -> AvatarContent
    private var entries: [Entry] = []

    init(build: @escaping (BotAvatarSpec, ColorScheme, AvatarColor?) -> AvatarContent = AvatarContentStore.make) {
        self.build = build
    }

    static func make(_ spec: BotAvatarSpec, _ scheme: ColorScheme, _ eyeInk: AvatarColor?) -> AvatarContent {
        var built = AvatarContent(spec).toned(for: scheme)
        if let eyeInk { built = built.eyeInked(eyeInk) }
        return built
    }

    func content(for spec: BotAvatarSpec, scheme: ColorScheme, eyeInk: AvatarColor?) -> AvatarContent {
        lock.lock()
        defer { lock.unlock() }
        if let hit = entries.first(where: { $0.spec == spec && $0.scheme == scheme && $0.eyeInk == eyeInk }) {
            return hit.content
        }
        let built = build(spec, scheme, eyeInk)
        entries.append(Entry(spec: spec, scheme: scheme, eyeInk: eyeInk, content: built))
        if entries.count > Self.capacity { entries.removeFirst() }
        return built
    }
}
