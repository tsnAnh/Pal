import Foundation
import PalChat
import PalClient
import PalDiagnostics
import PalTransport

struct LiveChatConnector: ChatConnector {
    let connection: ConnectionModel

    func connect() async throws -> GatewayConnection {
        guard let connector = await connection.chatConnector else { throw PalClientError.notSignedIn }
        return try await connector.connect()
    }
}

struct BotLink: Sendable {
    let outbox: Outbox
    let sessions: SessionHub
}

@MainActor
final class BotLinks {
    private let connection: ConnectionModel
    private var links: [String: BotLink] = [:]
    private let warm = WarmSessionPool()
    let snapshots = ChatSnapshotMemory()
    let drafts: DraftStore
    private let draftFlush: DraftFlushTriggers
    private let timelineStore: @MainActor (String) -> any TimelineStore
    private(set) lazy var heights = ChatRowHeightStore(cache: connection.cache) { [unowned connection] in connection.accountKey }

    init(
        connection: ConnectionModel,
        drafts: DraftStore = DraftStore(directory: BotLinks.draftsDirectory, diagnostics: .osLog()),
        timelineStore: (@MainActor (String) -> any TimelineStore)? = nil
    ) {
        self.connection = connection
        self.drafts = drafts
        self.timelineStore = timelineStore ?? { [unowned connection] bot in
            ConversationTimelineStore(bot: bot) { (connection.cache, connection.accountKey) }
        }
        draftFlush = DraftFlushTriggers(store: drafts)
    }

    static var draftsDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "drafts", directoryHint: .isDirectory)
    }

    func link(for bot: String) throws -> BotLink {
        if let existing = links[bot] { return existing }
        let connection = self.connection
        let store = timelineStore(bot)
        let hub = SessionHub(
            profile: bot, connector: LiveChatConnector(connection: connection), store: store, pool: warm, diagnostics: .osLog()
        )
        let link = BotLink(outbox: try Outbox(directory: Self.outboxDirectory(for: bot), submitter: hub), sessions: hub)
        links[bot] = link
        return link
    }

    func preload(_ bots: [String]) async {}

    private static func outboxDirectory(for name: String) -> URL {
        let base = URL.applicationSupportDirectory.appending(path: "outbox", directoryHint: .isDirectory)
        let safe = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "bot"
        return base.appending(path: safe, directoryHint: .isDirectory)
    }
}
