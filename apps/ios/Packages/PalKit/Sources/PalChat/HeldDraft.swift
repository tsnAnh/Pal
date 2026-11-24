import Foundation
import PalProtocol
import PalTransport

public enum HeldDraftChoice: String, Sendable, Hashable {
    case once
    case deny
}

public enum HeldDraftOutcome: Sendable, Hashable {
    case sent
    case cancelled
}

public struct HeldDraft: Sendable, Hashable, Identifiable {
    public enum Standing: Sendable, Hashable {
        case waiting
        case failed(reason: String?)
        case expired
    }

    public static let promptPrefix = "draft:"

    public let id: String
    public let channel: String
    public let recipient: String
    public let text: String
    public let standing: Standing
    public let canSend: Bool
    public let canEdit: Bool
    public let expiresAt: Date?

    public init(
        id: String,
        channel: String,
        recipient: String,
        text: String,
        standing: Standing = .waiting,
        canSend: Bool = true,
        canEdit: Bool = true,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.channel = channel
        self.recipient = recipient
        self.text = text
        self.standing = standing
        self.canSend = canSend
        self.canEdit = canEdit
        self.expiresAt = expiresAt
    }

    public init?(card: JSONValue) {
        guard let requestID = card["request_id"]?.stringValue, requestID.hasPrefix(Self.promptPrefix),
              requestID.count > Self.promptPrefix.count,
              let draft = card["draft"], draft["kind"]?.stringValue == "outbound_message",
              let text = draft["text"]?.stringValue ?? card["command"]?.stringValue
        else { return nil }
        let choices = card["choices"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let state = draft["state"]?.stringValue
        id = String(requestID.dropFirst(Self.promptPrefix.count))
        channel = draft["channel"]?.stringValue ?? ""
        recipient = draft["recipient"]?.stringValue ?? ""
        self.text = text
        switch state {
        case "expired": standing = .expired
        case "failed": standing = .failed(reason: Self.reason(draft["error"]?.stringValue))
        default: standing = .waiting
        }
        canSend = choices.contains(HeldDraftChoice.once.rawValue) && state != "expired"
        canEdit = canSend && draft["editable"]?.boolValue == true
        switch draft["expires_at"] {
        case .double(let seconds)?: expiresAt = Date(timeIntervalSince1970: seconds)
        case .int(let seconds)?: expiresAt = Date(timeIntervalSince1970: TimeInterval(seconds))
        default: expiresAt = nil
        }
    }

    public var promptID: String { Self.promptPrefix + id }

    public var channelName: String {
        let name = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = name.first else { return String(localized: "your messaging app") }
        return first.uppercased() + name.dropFirst()
    }

    public var recipientName: String {
        let name = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "someone") : name
    }

    public var headerLine: String { header(waiting: true) }

    public func header(waiting: Bool) -> String {
        waiting
            ? String(localized: "Message to \(recipientName) on \(channelName) (waiting)")
            : String(localized: "Message to \(recipientName) on \(channelName)")
    }

    static func reason(_ raw: String?) -> String? {
        var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        while text.hasSuffix(".") { text.removeLast() }
        return text.isEmpty ? nil : text
    }
}

public struct HeldDraftEntry: Sendable, Hashable, Identifiable {
    public let bot: HeldDraftBot
    public let draft: HeldDraft

    public init(bot: HeldDraftBot, draft: HeldDraft) {
        self.bot = bot
        self.draft = draft
    }

    public var id: String { "\(bot.name)/\(draft.id)" }

    public func statusLine(now: Date = Date()) -> String {
        switch draft.standing {
        case .expired: return String(localized: "Expired")
        case .failed: return String(localized: "Not sent, waiting")
        case .waiting:
            guard let expiresAt = draft.expiresAt, expiresAt > now else { return String(localized: "Waiting") }
            let left = expiresAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
            return String(localized: "Waiting, expires \(left)")
        }
    }
}

public struct HeldDraftBot: Sendable, Hashable, Identifiable {
    public let name: String
    public let displayName: String

    public init(name: String, displayName: String) {
        self.name = name
        self.displayName = displayName
    }

    public var id: String { name }
}

public struct HeldDraftRefusal: Error, Sendable, Equatable {
    public static let wireCode = 4134

    public let reason: String
    public let state: String?
    public let message: String

    public init(reason: String, state: String?, message: String) {
        self.reason = reason
        self.state = state
        self.message = message
    }

    public init?(_ error: any Error) {
        guard case GatewayTransportError.rpc(let rpc) = error, rpc.code == Self.wireCode else { return nil }
        self.init(reason: rpc.reasonCode ?? "", state: rpc.data?["state"]?.stringValue, message: rpc.message)
    }

    private static let failurePrefix = "The message was NOT sent: "
    private static let failureSuffix = ". It is still waiting for approval; approve it again to retry."

    public var sendFailureReason: String? {
        guard message.hasPrefix(Self.failurePrefix) else { return nil }
        var body = String(message.dropFirst(Self.failurePrefix.count))
        if body.hasSuffix(Self.failureSuffix) { body.removeLast(Self.failureSuffix.count) }
        return HeldDraft.reason(body)
    }
}

public enum HeldDraftDeskError: Error, Sendable, Equatable {
    case unreachable
}
