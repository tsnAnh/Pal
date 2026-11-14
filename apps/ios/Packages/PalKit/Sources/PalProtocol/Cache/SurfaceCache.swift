import Foundation

public struct SurfaceKey: Hashable, Sendable {
    let name: String

    public static func screen(_ screen: String) -> SurfaceKey {
        SurfaceKey(name: "surface-\(screen)")
    }

    public static func screen(_ screen: String, bot: String) -> SurfaceKey {
        SurfaceKey(name: "surface-\(screen)-\(bot)")
    }
}

@MainActor
public final class SurfaceCache {
    private let store: CacheStore
    private let account: () -> String
    private var memory: [String: any Sendable] = [:]

    public init(store: CacheStore, account: @escaping () -> String) {
        self.store = store
        self.account = account
    }

    public func remembered<Value: Sendable>(_ type: Value.Type, _ key: SurfaceKey) -> Value? {
        memory[slot(key)] as? Value
    }

    public func remember<Value: Sendable>(_ value: Value, _ key: SurfaceKey) {
        memory[slot(key)] = value
    }

    public func value<Value: Codable & Sendable>(_ type: Value.Type, _ key: SurfaceKey) async -> Value? {
        if let held = remembered(type, key) { return held }
        let owner = account()
        guard let stored = await store.loadDetached(type, name: key.name, account: owner) else { return nil }
        guard owner == account() else { return nil }
        if memory[slot(key)] == nil { memory[slot(key)] = stored }
        return remembered(type, key)
    }

    public func persist<Value: Codable & Sendable>(_ value: Value, _ key: SurfaceKey) {
        remember(value, key)
        store.save(value, name: key.name, account: account())
    }

    public func forget(_ key: SurfaceKey) {
        memory[slot(key)] = nil
        store.remove(name: key.name, account: account())
    }

    public func forgetAll() {
        memory.removeAll()
    }

    private func slot(_ key: SurfaceKey) -> String {
        "\(account())\u{0}\(key.name)"
    }
}
