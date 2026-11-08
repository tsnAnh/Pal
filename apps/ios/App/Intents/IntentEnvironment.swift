import Foundation
import HermesChat
import HermesProtocol
import HermesRoster

@MainActor
final class IntentEnvironment {
    private static let connectPolls = 150

    let connection: ConnectionModel
    let roster: RosterModel
    private let links: BotLinks

    init(connection: ConnectionModel, roster: RosterModel, links: BotLinks) {
        self.connection = connection
        self.roster = roster
        self.links = links
    }

    func bots() async throws -> [BotEntity] {
        try await ensureConnected()
        let result: JSONValue
        do {
            result = try await connection.rpc("profiles.list", ["include_sessions": false])
        } catch {
            throw BotIntentError.unreachable
        }
        return BotProfile.parse(result["profiles"]?.arrayValue ?? []).map(BotEntity.init)
    }

    func activity(of bot: BotEntity) async throws -> BotActivity {
        try await ensureConnected()
        let snapshot: RosterSnapshot
        do {
            snapshot = try await RosterSnapshotFetcher.fetch(call: { [connection] method, params in
                try await connection.rpc(method, params)
            })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BotIntentError.unreachable
        }
        guard let activity = snapshot.activity(of: bot.id) else { throw BotIntentError.unknownBot }
        return activity
    }

    func withErrand<Result: Sendable>(
        for bot: BotEntity,
        _ body: @MainActor (BotErrand) async throws -> Result
    ) async throws -> Result {
        try await ensureConnected()
        let link: BotLink
        do {
            link = try links.link(for: bot.id)
        } catch {
            throw BotIntentError.notSaved
        }
        let session = await link.sessions.acquire()
        let errand = BotErrand(botID: bot.id, session: session, outbox: link.outbox)
        do {
            let result = try await body(errand)
            await link.sessions.release(session)
            return result
        } catch let error as ErrandError {
            await link.sessions.release(session)
            throw BotIntentError(error)
        } catch {
            await link.sessions.release(session)
            throw error
        }
    }

    func tell(_ text: String, files: [OutgoingFile] = [], to bot: BotEntity) async throws -> ErrandMark {
        try await withErrand(for: bot) { errand in
            try await errand.tell(text, files: files)
        }
    }

    func open(_ bot: BotEntity) {
        roster.open(botNamed: bot.id)
    }

    func draft(_ text: String, for bot: BotEntity) {
        if !text.isEmpty { roster.drafts[bot.id] = text }
        roster.open(botNamed: bot.id)
    }

    private func ensureConnected() async throws {
        await connection.restore()
        for _ in 0..<Self.connectPolls where connection.isBusy { try await Task.sleep(for: .milliseconds(100)) }
        await connection.retryConnection()
        switch connection.phase {
        case .connected: return
        case .signedOut: throw BotIntentError.signedOut
        default: throw BotIntentError.unreachable
        }
    }
}
