import AppIntents
import HermesChat

enum BotIntentError: Error, CustomLocalizedStringResourceConvertible {
    case signedOut
    case unreachable
    case notSaved
    case refused
    case unknownBot
    case oneBotAtATime
    case unsupportedMessage
    case notAccepted
    case fileTooLarge(name: String)
    case fileEmpty(name: String)
    case fileUnsupported(name: String)
    case fileUnreadable(name: String)
    case tooManyFiles
    case nothingToSend
    case draftHasNoFiles

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut: "Sign in to Hermes Bots first."
        case .unreachable: "Hermes Bots can't reach your Hermes right now."
        case .notSaved: "Hermes Bots couldn't save your message."
        case .refused: "Hermes didn't accept that message."
        case .unknownBot: "That bot isn't available any more."
        case .oneBotAtATime: "Hermes Bots can message one bot at a time."
        case .unsupportedMessage: "Hermes Bots can't send that kind of message yet."
        case .notAccepted: "Hermes didn't accept that. It may already have been handled."
        case .fileTooLarge(let name): "\(name) is too large to send. Files can be up to 25 MB."
        case .fileEmpty(let name): "\(name) is empty, so there is nothing to send."
        case .fileUnsupported(let name): "Hermes Bots can't send \(name). Try an image, a PDF or a text file."
        case .fileUnreadable(let name): "Hermes Bots couldn't read \(name)."
        case .tooManyFiles: "Hermes Bots can send up to 10 files at a time."
        case .nothingToSend: "Add a file or a note to send."
        case .draftHasNoFiles: "Hermes Bots can't keep files in a draft. Send the message instead."
        }
    }

    init(_ error: ErrandError) {
        self = switch error {
        case .unreachable: .unreachable
        case .signInRequired: .signedOut
        case .notSaved: .notSaved
        case .refused: .refused
        case .notAccepted: .notAccepted
        }
    }

    init(_ error: any Error) {
        switch error {
        case AttachmentError.tooLarge(let name): self = .fileTooLarge(name: name)
        case AttachmentError.empty(let name): self = .fileEmpty(name: name)
        case AttachmentError.unsupported(let name): self = .fileUnsupported(name: name)
        case AttachmentError.unreadable(let name): self = .fileUnreadable(name: name)
        case AttachmentError.tooMany: self = .tooManyFiles
        case let error as ErrandError: self.init(error)
        case let error as BotIntentError: self = error
        default: self = .unreachable
        }
    }
}
