import Foundation
import HermesChat
import HermesClient
import HermesDesign
import HermesDiagnostics
import HermesProtocol
import HermesRoster
import Observation

struct BotRow: Identifiable, Equatable {
    let name: String
    let isDefault: Bool
    var isPrimary: Bool
    var isPinned: Bool
    var isHidden = false
    var isUnread = false
    var displayName: String
    let conversationID: String?
    let preview: ClassifiedPreview
    let lastActive: Date?
    let spec: BotAvatarSpec
    let accent: BotAccent?
    let usesPrimaryLook: Bool
    let sessionIDs: Set<String>

    var id: String { name }

    var searchBot: SearchBot { SearchBot(name: name, displayName: displayName, sessionIDs: sessionIDs) }
}

private struct AssetWire: Decodable {
    var found: Bool
    var data: String?
}

@MainActor
@Observable
final class RosterModel {
    private(set) var bots: [BotRow] = []
    private(set) var isLoaded = false
    private(set) var link: GatewayLink = .reconnecting
    private(set) var live: [String: BotLiveState] = [:]
    private(set) var celebrating: Set<String> = []
    private(set) var capabilities = RosterCapabilities()
    private(set) var adminError: BotAdminError?
    var drafts: [String: String] = [:]

    let connection: ConnectionModel
    private var photos: [String: Data] = [:]
    private var feed: RosterLiveFeed?
    private var serverBots: [BotRow] = []
    private var provisional: [String: BotRow] = [:]
    private var pinOverrides: [String: Bool] = [:]
    private var hideOverrides: [String: Bool] = [:]
    private var titleOverrides: [String: String] = [:]
    private var deleted: Set<String> = []
    private var unread: Set<String> = []
    private var marksAccount: String?
    private var primaryOverride: String?
    private var pendingIntros: [String: BotIntro] = [:]
    private var photoChecked: Set<String> = []
    private var lastSnapshot: RosterSnapshot?
    private var lastPersisted: RosterCacheEntry?
    private var profiles: [RosterProfile] = []

    init(connection: ConnectionModel) {
        self.connection = connection
        hydrateFromCache()
    }

    var hasContent: Bool { !bots.isEmpty }

    func reset() {
        bots = []
        serverBots = []
        provisional = [:]
        pinOverrides = [:]
        hideOverrides = [:]
        titleOverrides = [:]
        deleted = []
        unread = []
        marksAccount = nil
        primaryOverride = nil
        pendingIntros = [:]
        photos = [:]
        photoChecked = []
        profiles = []
        lastSnapshot = nil
        lastPersisted = nil
        live = [:]
        drafts = [:]
        isLoaded = false
    }

    private func hydrateFromCache() {
        guard !connection.baseURLText.isEmpty,
              let entry = connection.cache.load(RosterCacheEntry.self, name: RosterCache.name, account: connection.accountKey)
        else { return }
        let cached = entry.profiles.compactMap(RosterProfile.init)
        guard !cached.isEmpty else { return }
        photos = entry.photos
        capabilities = entry.capabilities
        lastPersisted = entry
        syncMarks()
        profiles = cached
        rebuildServerBots()
        publish()
        LaunchClock.mark("roster hydrated from cache (\(cached.count) bots)", on: .osLog())
    }

    private func rebuildServerBots() {
        let senders = profiles.map { PreviewSender(name: $0.name, displayName: Self.displayName(of: $0)) }
        serverBots = profiles.map { row(from: $0, senders: senders) }
    }

    private func persist(_ snapshot: RosterSnapshot) {
        guard !snapshot.profiles.isEmpty else { return }
        let entry = RosterCache.entry(from: snapshot, photos: photos)
        if let lastPersisted, lastPersisted.hasSameContent(as: entry) { return }
        lastPersisted = entry
        connection.cache.save(entry, name: RosterCache.name, account: connection.accountKey)
    }

    private func fetchAvatars(_ names: [String]) async -> [String: Data] {
        guard !names.isEmpty else { return [:] }
        return await withTaskGroup(of: (String, Data?).self) { group in
            for name in names { group.addTask { (name, await self.fetchAvatar(name)) } }
            var fetched: [String: Data] = [:]
            for await (name, data) in group { if let data { fetched[name] = data } }
            return fetched
        }
    }

    private func revalidatePhotos(_ names: [String]) {
        guard !names.isEmpty else { return }
        photoChecked.formUnion(names)
        Task {
            let fresh = await fetchAvatars(names)
            var changed = false
            for (name, data) in fresh where photos[name] != data {
                photos[name] = data
                changed = true
            }
            guard changed, isLoaded else { return }
            rebuildServerBots()
            publish()
            if let lastSnapshot { persist(lastSnapshot) }
        }
    }

    var visibleBots: [BotRow] { bots.filter { !$0.isHidden } }

    var hiddenBots: [BotRow] { bots.filter(\.isHidden) }

    var pinned: [BotRow] { visibleBots.filter(\.isPinned) }

    var rows: [BotRow] { visibleBots.filter { !$0.isPinned } }

    var accentBot: BotRow? { pinned.first ?? visibleBots.first(where: \.isPrimary) }

    var replacementPrimaries: [BotRow] { bots.filter { !$0.isPrimary } }

    var searchBots: [SearchBot] {
        let leading = bots.filter { $0.isPinned || $0.isPrimary }.sorted { ($0.isPinned ? 0 : 1, $0.isPrimary ? 0 : 1) < ($1.isPinned ? 0 : 1, $1.isPrimary ? 0 : 1) }
        return (leading + bots.filter { !($0.isPinned || $0.isPrimary) }).map(\.searchBot)
    }

    func bot(named name: String) -> BotRow? {
        bots.first { $0.name == name }
    }

    func botName(forSessionID sessionID: String) -> String? {
        bots.first { $0.sessionIDs.contains(sessionID) }?.name
    }

    func activity(for name: String) -> BotActivity {
        BotActivity.derive(link: link, live: live[name], hasLocalPrompt: false, now: Date())
    }

    func avatarMood(for name: String) -> AvatarMood {
        celebrating.contains(name) ? .done : activity(for: name).avatarMood
    }

    func takeIntro(for name: String) -> BotIntro? {
        pendingIntros.removeValue(forKey: name)
    }

    func dismissAdminError() {
        adminError = nil
    }

    private func celebrateFinishedWork(previous: [String: BotActivity]) {
        for (name, before) in previous where before == .working && activity(for: name) == .idle {
            celebrating.insert(name)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(AvatarMood.doneDuration))
                self?.celebrating.remove(name)
            }
        }
    }

    func runLive() async {
        guard feed == nil, let client = connection.client else { return }
        let presence = client.presence
        let feed = RosterLiveFeed(
            connect: { try await client.connect(reach: .offerTarget) },
            onEvent: { presence?.receive($0) },
            diagnostics: .osLog()
        )
        self.feed = feed
        await feed.start()
        await withTaskCancellationHandler {
            for await update in feed.updates {
                switch update {
                case .link(let next): link = next
                case .snapshot(let snapshot): await apply(snapshot)
                }
            }
        } onCancel: {
            Task { await feed.stop() }
        }
        self.feed = nil
    }

    func nudge() {
        guard let feed else { return }
        Task { await feed.nudge() }
    }

    private var admin: BotAdmin {
        BotAdmin(gateway: gateway, diagnostics: .osLog())
    }

    var gateway: RosterGateway {
        let connection = connection
        return RosterGateway { method, params in try await connection.rpc(method, params) }
    }

    func setPinned(_ bot: BotRow, pinned: Bool) {
        guard bot.isPinned != pinned else { return }
        pinOverrides[bot.name] = pinned
        publish()
        let name = bot.name
        Task {
            do {
                try await admin.setPinned(name, pinned: pinned)
                nudge()
            } catch {
                pinOverrides[name] = nil
                adminError = BotAdminError.classify(error)
                publish()
            }
        }
    }

    func setHidden(_ bot: BotRow, hidden: Bool) {
        guard bot.isHidden != hidden else { return }
        hideOverrides[bot.name] = hidden
        publish()
        let name = bot.name
        Task {
            do {
                try await admin.setHidden(name, hidden: hidden)
                nudge()
            } catch {
                hideOverrides[name] = nil
                adminError = BotAdminError.classify(error)
                publish()
            }
        }
    }

    func rename(_ bot: BotRow, to proposed: String) async throws {
        let title = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title != bot.displayName else { return }
        try await admin.rename(bot.name, isPrimary: bot.isPrimary, to: title)
        titleOverrides[bot.name] = title
        publish()
        nudge()
    }

    func delete(_ bot: BotRow) async {
        guard !bot.isPrimary else { return }
        do {
            try await admin.delete(bot.name)
        } catch is CancellationError {
            return
        } catch {
            report(error)
            return
        }
        deleted.insert(bot.name)
        LocalBotMarks(account: connection.accountKey).markRead(bot.name)
        unread.remove(bot.name)
        publish()
        nudge()
    }

    func report(_ error: any Error) {
        adminError = BotAdminError.classify(error)
    }

    func markUnread(_ bot: BotRow) {
        syncMarks()
        LocalBotMarks(account: connection.accountKey).markUnread(bot.name)
        unread.insert(bot.name)
        publish()
    }

    func markRead(_ name: String) {
        guard unread.contains(name) else { return }
        LocalBotMarks(account: connection.accountKey).markRead(name)
        unread.remove(name)
        publish()
    }

    func copyConversationID(_ bot: BotRow) {
        guard let id = bot.conversationID else { return }
        Pasteboard.string = id
    }

    func makePrimary(_ bot: BotRow) {
        guard !bot.isPrimary else { return }
        primaryOverride = bot.name
        publish()
        let name = bot.name
        Task {
            do {
                try await admin.makePrimary(name)
                nudge()
            } catch {
                primaryOverride = nil
                adminError = BotAdminError.classify(error)
                publish()
            }
        }
    }

    func create(_ request: NewBotRequest, spec: BotAvatarSpec) async throws -> CreatedBot {
        let provisioner = BotProvisioner(gateway: gateway, diagnostics: .osLog())
        let created = try await provisioner.create(request)
        pendingIntros[created.name] = BotIntro.forGateway(greetsUnprompted: created.greetsUnprompted)
        provisional[created.name] = BotRow(
            name: created.name,
            isDefault: false,
            isPrimary: false,
            isPinned: false,
            displayName: created.displayName,
            conversationID: nil,
            preview: ClassifiedPreview(kind: .plain, text: ""),
            lastActive: Date(),
            spec: spec,
            accent: nil,
            usesPrimaryLook: false,
            sessionIDs: []
        )
        publish()
        nudge()
        return created
    }

    private func apply(_ snapshot: RosterSnapshot) async {
        let profiles = snapshot.profiles.compactMap(RosterProfile.init)
        let avatarNames = Set(profiles.filter(\.hasAvatar).map(\.name))
        let uncached = avatarNames.filter { photos[$0] == nil }.sorted()
        let fetched = await fetchAvatars(uncached)
        photoChecked.formUnion(fetched.keys)
        photos.merge(fetched) { _, fresh in fresh }
        photos = photos.filter { avatarNames.contains($0.key) }
        let previous = Dictionary(uniqueKeysWithValues: bots.map { ($0.name, activity(for: $0.name)) })
        live = snapshot.live
        capabilities = snapshot.capabilities
        reconcileOverrides(with: profiles)
        syncMarks()
        LocalBotMarks(account: connection.accountKey).prune(keeping: Set(profiles.map(\.name)))
        unread.formIntersection(profiles.map(\.name))
        celebrateFinishedWork(previous: previous)
        self.profiles = profiles
        rebuildServerBots()
        for name in serverBots.map(\.name) { provisional[name] = nil }
        publish()
        let firstSnapshot = !isLoaded
        isLoaded = true
        lastSnapshot = snapshot
        persist(snapshot)
        if firstSnapshot {
            LaunchClock.mark("roster live snapshot applied (\(profiles.count) bots)", on: .osLog())
            if !profiles.isEmpty {
                connection.cache.prune(
                    account: connection.accountKey,
                    prefix: CachedTranscript.namePrefix,
                    keeping: Set(profiles.map { CachedTranscript.cacheName(forBot: $0.name) })
                )
            }
        }
        revalidatePhotos(avatarNames.subtracting(photoChecked).sorted())
    }

    private func syncMarks() {
        let account = connection.accountKey
        guard marksAccount != account else { return }
        marksAccount = account
        unread = LocalBotMarks(account: account).unread
    }

    private func reconcileOverrides(with profiles: [RosterProfile]) {
        for profile in profiles {
            if pinOverrides[profile.name] == profile.botMeta.isPinned { pinOverrides[profile.name] = nil }
            if hideOverrides[profile.name] == profile.botMeta.isHidden { hideOverrides[profile.name] = nil }
            if titleOverrides[profile.name] == Self.displayName(of: profile) { titleOverrides[profile.name] = nil }
        }
        if let name = primaryOverride, profiles.first(where: { $0.name == name })?.isPrimary == true {
            primaryOverride = nil
        }
        deleted.formIntersection(profiles.map(\.name))
    }

    private func publish() {
        let combined = serverBots + provisional.values.filter { extra in !serverBots.contains { $0.name == extra.name } }
        bots = combined.filter { !deleted.contains($0.name) }.map(applyingOverrides).sorted { lhs, rhs in
            switch (lhs.lastActive, rhs.lastActive) {
            case let (l?, r?): l > r
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
        }
    }

    private func applyingOverrides(_ bot: BotRow) -> BotRow {
        var row = bot
        row.isPinned = pinOverrides[bot.name] ?? bot.isPinned
        row.isHidden = hideOverrides[bot.name] ?? bot.isHidden
        row.isPrimary = primaryOverride.map { $0 == bot.name } ?? bot.isPrimary
        row.displayName = titleOverrides[bot.name] ?? bot.displayName
        row.isUnread = unread.contains(bot.name)
        return row
    }

    nonisolated static func displayName(name: String, displayName: String?, uiMeta: [String: Any]?) -> String {
        let botMeta = uiMeta?["hermes-bots"] as? [String: Any]
        if let title = (botMeta?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let display = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !display.isEmpty {
            return display
        }
        let slug = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if slug.lowercased() == "default" { return "Hermes" }
        let words = slug.replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return words.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    nonisolated static func displayName(of profile: RosterProfile) -> String {
        displayName(name: profile.name, displayName: profile.displayName, uiMeta: profile.uiMeta.flatMap(dictionary(from:)))
    }

    private func row(from profile: RosterProfile, senders: [PreviewSender]) -> BotRow {
        let uiMeta = profile.uiMeta.flatMap(Self.dictionary(from:))
        let lastActive = profile.canonical?.lastActive.map { Date(timeIntervalSince1970: $0) }
        return BotRow(
            name: profile.name,
            isDefault: profile.isDefault,
            isPrimary: profile.isPrimary,
            isPinned: profile.botMeta.isPinned,
            isHidden: profile.botMeta.isHidden,
            displayName: Self.displayName(of: profile),
            conversationID: profile.canonical?.resolvedID ?? profile.canonical?.id,
            preview: PreviewClassifier.classify(profile.canonical?.preview, senders: senders),
            lastActive: lastActive,
            spec: BotAvatarSpec(name: profile.name, uiMeta: uiMeta, photo: photos[profile.name]),
            accent: BotAccent(name: profile.name, uiMeta: uiMeta),
            usesPrimaryLook: profile.name.lowercased() == BotAvatarSpec.primaryName && !BotAvatarMeta(uiMeta: uiMeta).custom,
            sessionIDs: Set([profile.canonical?.id, profile.canonical?.resolvedID].compactMap { $0 })
        )
    }

    private func fetchAvatar(_ name: String) async -> Data? {
        guard let result = try? await connection.rpc("profiles.get_asset", ["name": .string(name), "asset": "avatar"]),
              let asset = try? result.decoded(as: AssetWire.self), asset.found,
              let url = asset.data, let comma = url.firstIndex(of: ",")
        else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]))
    }

    private nonisolated static func dictionary(from value: JSONValue) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum ClockTime {
    static func label(for date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

enum RosterTimestamp {
    static func label(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return ClockTime.label(for: date) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        let startOfToday = calendar.startOfDay(for: now)
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday), date >= weekAgo {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
