import Foundation
import HermesClient
import HermesDesign
import HermesProtocol
import HermesRoster
import Observation

struct BotRow: Identifiable, Equatable {
    let name: String
    let displayName: String
    let isDefault: Bool
    let preview: String
    let lastActive: Date?
    let spec: BotAvatarSpec
    let accent: BotAccent?
    let sessionIDs: Set<String>

    var id: String { name }
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
    var query = ""
    var path: [String] = []
    var drafts: [String: String] = [:]

    private let connection: ConnectionModel
    private var photos: [String: Data] = [:]
    private var feed: RosterLiveFeed?

    init(connection: ConnectionModel) {
        self.connection = connection
    }

    var hero: BotRow? { bots.first { $0.isDefault } }

    var rows: [BotRow] {
        let others = bots.filter { !$0.isDefault }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return others }
        return others.filter { $0.displayName.localizedStandardContains(needle) || $0.name.localizedStandardContains(needle) }
    }

    func bot(named name: String) -> BotRow? {
        bots.first { $0.name == name }
    }

    @discardableResult
    func open(sessionID: String) -> Bool {
        guard let bot = bots.first(where: { $0.sessionIDs.contains(sessionID) }) else { return false }
        if path.last != bot.name { path = [bot.name] }
        return true
    }

    func open(botNamed name: String) {
        if path.last != name { path = [name] }
    }

    func activity(for name: String) -> BotActivity {
        BotActivity.derive(link: link, live: live[name], hasLocalPrompt: false, now: Date())
    }

    func avatarMood(for name: String) -> AvatarMood {
        celebrating.contains(name) ? .done : activity(for: name).avatarMood
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

    private func apply(_ snapshot: RosterSnapshot) async {
        let profiles = BotProfile.parse(snapshot.profiles)
        for profile in profiles where profile.hasAvatar == true && photos[profile.name] == nil {
            if let data = await fetchAvatar(profile.name) { photos[profile.name] = data }
        }
        let previous = Dictionary(uniqueKeysWithValues: bots.map { ($0.name, activity(for: $0.name)) })
        live = snapshot.live
        celebrateFinishedWork(previous: previous)
        bots = profiles.map { row(from: $0) }.sorted { lhs, rhs in
            switch (lhs.lastActive, rhs.lastActive) {
            case let (l?, r?): l > r
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
        }
        isLoaded = true
    }

    private func row(from profile: BotProfile) -> BotRow {
        let uiMeta = profile.uiMetaObject
        let preview = profile.canonicalSession?.preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lastActive = profile.canonicalSession?.lastActive.map { Date(timeIntervalSince1970: $0) }
        return BotRow(
            name: profile.name,
            displayName: profile.title,
            isDefault: profile.isDefault ?? false,
            preview: preview,
            lastActive: lastActive,
            spec: BotAvatarSpec(name: profile.name, uiMeta: uiMeta, photo: photos[profile.name]),
            accent: BotAccent(name: profile.name, uiMeta: uiMeta),
            sessionIDs: Set([profile.canonicalSession?.id, profile.canonicalSession?.resolvedId].compactMap { $0 })
        )
    }

    private func fetchAvatar(_ name: String) async -> Data? {
        guard let result = try? await connection.rpc("profiles.get_asset", ["name": .string(name), "asset": "avatar"]),
              let asset = try? result.decoded(as: AssetWire.self), asset.found,
              let url = asset.data, let comma = url.firstIndex(of: ",")
        else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]))
    }
}

enum RosterTimestamp {
    static func label(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().locale(Locale(identifier: "en_GB")))
        }
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
