import Foundation
import PalChat
import PalDesign
import PalProtocol

enum BubbleDelivery: Equatable {
    case sent
    case sending
    case failed(submissionID: String)
}

struct ReplyTarget: Equatable {
    enum Author: Equatable {
        case you
        case bot
    }

    let rowID: String
    let author: Author
    let quote: String
}

struct ParsedMarkdown: Equatable {
    let source: String
    let deferred: DeferredMarkdown
    var document: MarkdownDocument { deferred.document }

    init(source: String, document: MarkdownDocument) {
        self.source = source
        deferred = DeferredMarkdown(source, parsed: document)
    }

    init(deferring source: String) {
        self.source = source
        deferred = DeferredMarkdown(source)
    }

    static func == (lhs: ParsedMarkdown, rhs: ParsedMarkdown) -> Bool { lhs.source == rhs.source }
}

struct ChatRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case user(text: String, delivery: BubbleDelivery)
        case assistant(ParsedMarkdown)
        case clarifyAnswered([ClarifyRecord])
        case clarify(PendingPrompt)
        case connection(ConnectionCard), noProvider
        case notice(ChatNotice)
        case botThread(BotThreadLink)
        case imageGeneration(ImageGeneration)
    }

    let id: String
    let kind: Kind
    var separator: Date?
    var showsUnreadDivider = false
    var gap: ChatRowGap = .none
    var images: [ImageReference] = []
    var files: [FileReference] = []
    var isStreaming = false
    var storedRowID: Int?

    var searchableText: String? {
        switch kind {
        case .user(let text, _): text
        case .assistant(let parsed): parsed.source
        case .notice(.botMessage(_, let body)): body
        default: nil
        }
    }
}

enum ChatConnectionState: Equatable {
    case connecting
    case live
    case reconnecting
}

struct VoiceReply: Equatable {
    var text: String
    var isComplete: Bool
    var turn: Int
}

enum OlderHistory: Equatable {
    case idle
    case loading
    case failed
    case complete

    init(_ state: OlderState) {
        switch state {
        case .more, .unknown: self = .idle
        case .loading: self = .loading
        case .failed: self = .failed
        case .start: self = .complete
        }
    }

    var canLoad: Bool { self != .complete }
}
