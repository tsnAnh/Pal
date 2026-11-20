import PalDesign
import PalPush

@MainActor
final class PushAvatarSync {
    static let shared = PushAvatarSync()

    private let cache: PushAvatarCache?
    private var rendered: [String: BotAvatarSpec] = [:]
    private var latest: [BotRow] = []
    private var worker: Task<Void, Never>?
    private var pruned = false

    init(cache: PushAvatarCache? = PushAvatarSync.appGroupCache) {
        self.cache = cache
    }

    private static var appGroupCache: PushAvatarCache? {
        #if PAL_COMM_NOTIFICATIONS
        return PushAvatarCache.shared()
        #else
        return nil
        #endif
    }

    func sync(_ bots: [BotRow]) {
        guard cache != nil, !bots.isEmpty else { return }
        latest = bots
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        defer { worker = nil }
        guard let cache else { return }
        while true {
            let snapshot = latest
            let names = Set(snapshot.map(\.name))
            let stale = snapshot.filter { rendered[$0.name] != $0.spec }
            let retired = rendered.keys.contains { !names.contains($0) }
            if stale.isEmpty, pruned, !retired { return }
            for bot in stale {
                rendered[bot.name] = bot.spec
                guard let png = BotAvatarSnapshot.pngData(for: bot.spec) else { continue }
                let name = bot.name
                await Task.detached(priority: .utility) { cache.store(png, for: name) }.value
                await Task.yield()
            }
            if !pruned || retired {
                pruned = true
                rendered = rendered.filter { names.contains($0.key) }
                await Task.detached(priority: .utility) { cache.prune(keeping: names) }.value
            }
        }
    }
}
