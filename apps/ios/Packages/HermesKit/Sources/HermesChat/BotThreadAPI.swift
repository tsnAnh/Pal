import Foundation
import HermesProtocol

public enum BotThreadReadMode: Sendable, Equatable {
    case newest
    case focus(exchangeID: String)
    case before(Int)
    case after(Int)
    case sinceRevision(Int)
}

extension SessionAPI {
    public func botThreadLinks(sessionID: String, limit: Int = 200) async throws -> BotThreadLinksResult {
        let result = try await call("bot.thread.links", [
            "session_id": .string(sessionID),
            "limit": .int(limit),
        ])
        return try decode(BotThreadLinksResult.self, result, "bot.thread.links")
    }

    public func botThreadRead(threadID: String, mode: BotThreadReadMode = .newest, limit: Int = 50) async throws -> BotThreadPage {
        var params: [String: JSONValue] = ["thread_id": .string(threadID), "limit": .int(limit)]
        switch mode {
        case .newest: break
        case .focus(let exchangeID): params["focus"] = .string(exchangeID)
        case .before(let cursor): params["before"] = .int(cursor)
        case .after(let cursor): params["after"] = .int(cursor)
        case .sinceRevision(let revision): params["since_rev"] = .int(revision)
        }
        let result = try await call("bot.thread.read", params)
        return try decode(BotThreadPage.self, result, "bot.thread.read")
    }
}
