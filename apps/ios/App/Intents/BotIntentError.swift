import AppIntents
import PalChat

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
        case .signedOut: "Sign in to Pal first."
        case .unreachable: "Pal can't reach your Hermes right now."
        case .notSaved: "Pal couldn't save your message."
        case .refused: "Hermes didn't accept that message."
        case .unknownBot: "That bot isn't available any more."
        case .oneBotAtATime: "Pal can message one bot at a time."
        case .unsupportedMessage: "Pal can't send that kind of message yet."
        case .notAccepted: "Hermes didn't accept that. It may already have been handled."
        case .fileTooLarge(let name): "\(name) is too large to send. Files can be up to 25 MB."
        case .fileEmpty(let name): "\(name) is empty, so there is nothing to send."
        case .fileUnsupported(let name): "Pal can't send \(name). Try an image, a PDF or a text file."
        case .fileUnreadable(let name): "Pal couldn't read \(name)."
        case .tooManyFiles: "Pal can send up to 10 files at a time."
        case .nothingToSend: "Add a file or a note to send."
        case .draftHasNoFiles: "Pal can't keep files in a draft. Send the message instead."
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
        case PalChat.AttachmentError.tooLarge(let name): self = .fileTooLarge(name: name)
        case PalChat.AttachmentError.empty(let name): self = .fileEmpty(name: name)
        case PalChat.AttachmentError.unsupported(let name): self = .fileUnsupported(name: name)
        case PalChat.AttachmentError.unreadable(let name): self = .fileUnreadable(name: name)
        case PalChat.AttachmentError.tooMany: self = .tooManyFiles
        case let error as ErrandError: self.init(error)
        case let error as BotIntentError: self = error
        default: self = .unreachable
        }
    }
}
