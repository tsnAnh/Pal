import AppIntents
import HermesChat
import HermesProtocol

struct ErrandReport: Sendable {
    let spoken: String
    let offersChat: Bool

    var dialog: IntentDialog {
        IntentDialog(LocalizedStringResource(stringLiteral: spoken))
    }

    init(outcome: ErrandOutcome, botName: String) {
        switch outcome {
        case .replied(let text):
            self.init(spoken: text, offersChat: false)
        case .needsInput(let prompt):
            self.init(spoken: PromptWording.relay(prompt, from: botName), offersChat: true)
        case .stillWorking:
            let ask = VoicePhrase.lastReply(botName)
            self.init(spoken: String(localized: "\(botName) is still working on it. Say “\(ask)” later to hear the answer, or open the chat."), offersChat: true)
        case .failed:
            self.init(spoken: String(localized: "\(botName) ran into a problem with that. Open the chat to look."), offersChat: true)
        case .finishedQuietly:
            self.init(spoken: String(localized: "\(botName) finished and had nothing more to say."), offersChat: false)
        }
    }

    init(answer: ErrandAnswer, botName: String) {
        switch answer {
        case .answered(let outcome):
            self.init(outcome: outcome, botName: botName)
        case .nothingToAnswer(let waiting?) where waiting.kind == .approval:
            let invitation = PromptWording.invitation(for: waiting, from: botName)
            self.init(spoken: String(localized: "\(botName) isn't waiting for an answer, but needs your approval. \(invitation)"), offersChat: false)
        case .nothingToAnswer:
            self.init(spoken: String(localized: "\(botName) isn't waiting for an answer."), offersChat: false)
        }
    }

    init(spoken: String, offersChat: Bool) {
        self.spoken = spoken
        self.offersChat = offersChat
    }
}
