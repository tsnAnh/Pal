import CoreGraphics
import Foundation
import Observation
import PalProtocol
import PalSettings

struct CachedOwnerPhoto: Codable, Sendable {
    let version: String
    let jpeg: Data
}

@MainActor
@Observable
final class OwnerProfile {
    nonisolated static let cacheName = "owner-photo"

    private(set) var name = ""
    private(set) var photo: CGImage?
    private(set) var hasLoaded = false

    @ObservationIgnored private let cache: CacheStore
    @ObservationIgnored private let account: () -> String
    @ObservationIgnored private let api: () -> SettingsAPI
    @ObservationIgnored private var photoVersion = ""
    @ObservationIgnored private var photoTask: Task<Void, Never>?
    @ObservationIgnored private var loadedAccount = ""

    init(cache: CacheStore, account: @escaping () -> String, api: @escaping () -> SettingsAPI) {
        self.cache = cache
        self.account = account
        self.api = api
    }

    func initial(fallback: String) -> String {
        name.first(where: \.isLetter).map { String($0).uppercased() } ?? fallback
    }

    func load() async {
        let current = account()
        if current != loadedAccount { reset() }
        loadedAccount = current
        guard let facts = try? await api().aboutYou(), account() == current else { return }
        adopt(facts)
    }

    func adopt(_ facts: SettingsWire.AboutYou) {
        if name != facts.name { name = facts.name }
        if !hasLoaded { hasLoaded = true }
        syncPhoto(version: facts.photoVersion)
    }

    func setName(_ value: String) async throws {
        adopt(try await api().setOwnerName(value))
    }

    func setPhoto(_ jpeg: Data?) async throws {
        let facts = try await api().setOwnerPhoto(jpeg)
        if let jpeg, !facts.photoVersion.isEmpty {
            await prime(jpeg: jpeg, version: facts.photoVersion)
        }
        adopt(facts)
    }

    private func reset() {
        photoTask?.cancel()
        photoTask = nil
        name = ""
        photo = nil
        photoVersion = ""
        hasLoaded = false
    }

    private func syncPhoto(version: String) {
        guard version != photoVersion || (photo == nil && !version.isEmpty) else { return }
        photoTask?.cancel()
        guard !version.isEmpty else {
            photoTask = nil
            photoVersion = ""
            photo = nil
            return
        }
        let cache = cache
        let account = account()
        let api = api()
        photoTask = Task { [weak self] in
            let resolved = await Self.resolve(version: version, cache: cache, account: account, api: api)
            guard !Task.isCancelled, let self, let resolved else { return }
            photoVersion = resolved.version
            photo = resolved.image
        }
    }

    private func prime(jpeg: Data, version: String) async {
        photoTask?.cancel()
        photoTask = nil
        let cache = cache
        let account = account()
        cache.save(CachedOwnerPhoto(version: version, jpeg: jpeg), name: Self.cacheName, account: account)
        guard let image = await Task.detached(priority: .utility, operation: { try? OwnerPhotoImage.decode(jpeg) }).value else { return }
        photoVersion = version
        photo = image
    }

    private struct Resolved: Sendable {
        let version: String
        let image: CGImage
    }

    @concurrent private static func resolve(version: String, cache: CacheStore, account: String, api: SettingsAPI) async -> Resolved? {
        if let cached = await cache.loadDetached(CachedOwnerPhoto.self, name: cacheName, account: account),
           cached.version == version, let image = try? OwnerPhotoImage.decode(cached.jpeg) {
            return Resolved(version: version, image: image)
        }
        guard let download = try? await api.ownerPhoto(), let image = try? OwnerPhotoImage.decode(download.data) else { return nil }
        cache.save(CachedOwnerPhoto(version: download.version, jpeg: download.data), name: cacheName, account: account)
        return Resolved(version: download.version, image: image)
    }
}
