import Foundation
import PalDiagnostics
import PalProtocol

public struct BotIntro: Sendable, Hashable {
    public var text: String
    public var hidden: Bool

    public init(text: String, hidden: Bool) {
        self.text = text
        self.hidden = hidden
    }

    public static let kickoff = BotIntro(text: "Hey, tell me about yourself!", hidden: false)

    public static let birthNotice = BotIntro(
        text: "You were just created and your owner has opened this chat. Greet them first, in one or two short sentences: say who you are, and ask what job you should own unless you already have one.",
        hidden: true
    )

    public static func forGateway(greetsUnprompted: Bool) -> BotIntro {
        greetsUnprompted ? .birthNotice : .kickoff
    }
}

public struct BotChatResolution: Sendable {
    public var snapshot: SessionSnapshot
    public var created: Bool
}

public struct BotChatResolver: Sendable {
    public static let title = "Bot Chat"

    private let diagnostics: Diagnostics

    public init(diagnostics: Diagnostics = .silent) {
        self.diagnostics = diagnostics
    }

    public func lookup(_ api: SessionAPI) async throws -> SessionListRow? {
        try await api.list(title: Self.title).first { $0.title == Self.title }
    }

    public func open(_ api: SessionAPI) async throws -> BotChatResolution {
        if let row = try await lookup(api) {
            return BotChatResolution(snapshot: try await api.resume(sessionID: Self.target(of: row)), created: false)
        }
        if let adopted = try await lookup(api) {
            diagnostics.info("chat", "adopted a chat that appeared before create")
            return BotChatResolution(snapshot: try await api.resume(sessionID: Self.target(of: adopted)), created: false)
        }
        let minted = try await api.create(title: Self.title, requestID: UUID().uuidString, hidden: true)
        guard let registered = try await lookup(api) else { throw ChatError.titleNotApplied }
        let target = Self.target(of: registered)
        if target == minted.sessionID || registered.sessionID == minted.sessionID {
            return BotChatResolution(snapshot: minted, created: true)
        }
        diagnostics.warning("chat", "created chat lost the title race; adopting the registered one")
        return BotChatResolution(snapshot: try await api.resume(sessionID: target), created: false)
    }

    static func target(of row: SessionListRow) -> String {
        row.resolvedID ?? row.sessionID
    }
}
