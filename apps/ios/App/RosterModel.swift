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
    let displayName: String
    let isDefault: Bool
    let isPrimary: Bool
    let isPinned: Bool
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

    private let connection: ConnectionModel
    private var photos: [String: Data] = [:]
    private var feed: RosterLiveFeed?
    private var serverBots: [BotRow] = []
    private var provisional: [String: BotRow] = [:]
    private var pinOverrides: [String: Bool] = [:]
    private var primaryOverride: String?
    private var pendingIntros: [String: BotIntro] = [:]

    init(connection: ConnectionModel) {
        self.connection = connection
    }

    var pinned: [BotRow] { bots.filter(\.isPinned) }

    var rows: [BotRow] { bots.filter { !$0.isPinned } }

    var accentBot: BotRow? { pinned.first ?? bots.first(where: \.isPrimary) }

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
            displayName: created.displayName,
            isDefault: false,
            isPrimary: false,
            isPinned: false,
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
        for profile in profiles where profile.hasAvatar && photos[profile.name] == nil {
            if let data = await fetchAvatar(profile.name) { photos[profile.name] = data }
        }
        let previous = Dictionary(uniqueKeysWithValues: bots.map { ($0.name, activity(for: $0.name)) })
        live = snapshot.live
        capabilities = snapshot.capabilities
        reconcileOverrides(with: profiles)
        let senders = profiles.map { PreviewSender(name: $0.name, displayName: Self.displayName(of: $0)) }
        celebrateFinishedWork(previous: previous)
        serverBots = profiles.map { row(from: $0, senders: senders) }
        for name in serverBots.map(\.name) { provisional[name] = nil }
        publish()
        isLoaded = true
    }

    private func reconcileOverrides(with profiles: [RosterProfile]) {
        for profile in profiles {
            if pinOverrides[profile.name] == profile.botMeta.isPinned { pinOverrides[profile.name] = nil }
        }
        if let name = primaryOverride, profiles.first(where: { $0.name == name })?.isPrimary == true {
            primaryOverride = nil
        }
    }

    private func publish() {
        let combined = serverBots + provisional.values.filter { extra in !serverBots.contains { $0.name == extra.name } }
        bots = combined.map(applyingOverrides).sorted { lhs, rhs in
            switch (lhs.lastActive, rhs.lastActive) {
            case let (l?, r?): l > r
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
        }
    }

    private func applyingOverrides(_ bot: BotRow) -> BotRow {
        let pinned = pinOverrides[bot.name] ?? bot.isPinned
        let primary = primaryOverride.map { $0 == bot.name } ?? bot.isPrimary
        guard pinned != bot.isPinned || primary != bot.isPrimary else { return bot }
        return BotRow(
            name: bot.name, displayName: bot.displayName, isDefault: bot.isDefault, isPrimary: primary, isPinned: pinned,
            preview: bot.preview, lastActive: bot.lastActive, spec: bot.spec, accent: bot.accent,
            usesPrimaryLook: bot.usesPrimaryLook, sessionIDs: bot.sessionIDs
        )
    }

    static func displayName(name: String, displayName: String?, uiMeta: [String: Any]?) -> String {
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

    private static func displayName(of profile: RosterProfile) -> String {
        displayName(name: profile.name, displayName: profile.displayName, uiMeta: profile.uiMeta.flatMap(dictionary(from:)))
    }

    private func row(from profile: RosterProfile, senders: [PreviewSender]) -> BotRow {
        let uiMeta = profile.uiMeta.flatMap(Self.dictionary(from:))
        let lastActive = profile.canonical?.lastActive.map { Date(timeIntervalSince1970: $0) }
        return BotRow(
            name: profile.name,
            displayName: Self.displayName(of: profile),
            isDefault: profile.isDefault,
            isPrimary: profile.isPrimary,
            isPinned: profile.botMeta.isPinned,
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

    private static func dictionary(from value: JSONValue) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum ClockTime {
    static func label(for date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "en_GB")))
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
