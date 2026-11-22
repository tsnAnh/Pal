import PalChat
import PalDesign
import PalRoster

extension ChatModel {
    var avatars: ParticipantAvatars { ParticipantAvatars(roster: roster) }
    var activity: BotActivity { roster.activity(for: bot.name) }

    var isCatchingUp: Bool {
        switch connection {
        case .connecting: true
        case .reconnecting, .live: false
        }
    }

    var timelineItems: [TranscriptItem] { snapshot?.rows.map(\.item) ?? [] }

    var voiceTurn: Int {
        timelineItems.count { item in
            if case .user = item.content { item.inbound.isPerson } else { false }
        }
    }

    var voiceReply: VoiceReply {
        var parts: [String] = []
        for item in timelineItems.reversed() {
            switch item.content {
            case .user where item.inbound.isPerson:
                break
            case .assistant(let text, _, _) where !text.isEmpty:
                parts.append(text)
                continue
            default:
                continue
            }
            break
        }
        var text = parts.reversed().joined(separator: "\n\n")
        if let streaming = snapshot?.streamingText, !streaming.isEmpty {
            text = text.isEmpty ? streaming : text + "\n\n" + streaming
        }
        return VoiceReply(text: text, isComplete: !(snapshot?.isRunning ?? false), turn: voiceTurn)
    }
}
