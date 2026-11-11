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

    init(connection: ConnectionModel) {
        self.connection = connection
    }

    func link(for bot: String) throws -> BotLink {
        if let existing = links[bot] { return existing }
        let hub = SessionHub(profile: bot, connector: LiveChatConnector(connection: connection), diagnostics: .osLog())
        let link = BotLink(outbox: try Outbox(directory: Self.outboxDirectory(for: bot), submitter: hub), sessions: hub)
        links[bot] = link
        return link
    }

    private static func outboxDirectory(for name: String) -> URL {
        let base = URL.applicationSupportDirectory.appending(path: "outbox", directoryHint: .isDirectory)
        let safe = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "bot"
        return base.appending(path: safe, directoryHint: .isDirectory)
    }
}
