import Foundation
import PalProtocol

public struct BotChatHiddenTurn: Sendable {
    private let connector: any ChatConnector
    private let resolver = BotChatResolver()

    public init(connector: any ChatConnector) {
        self.connector = connector
    }

    public func deliver(_ text: String, to profile: String) async throws {
        let connection = try await connector.connect()
        let api = SessionAPI(connection: connection, profile: profile)
        do {
            guard let row = try await resolver.lookup(api) else { throw ChatError.noBotChat }
            let snapshot = try await api.resume(sessionID: BotChatResolver.target(of: row), messageLimit: 1)
            _ = try await api.submit(
                sessionID: snapshot.sessionID,
                text: text,
                submissionID: "teach:\(UUID().uuidString)",
                hidden: true
            )
        } catch {
            await connection.close()
            throw error
        }
        await connection.close()
    }
}
