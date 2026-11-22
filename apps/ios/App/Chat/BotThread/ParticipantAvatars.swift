import Foundation
import PalDesign
import PalProtocol

@MainActor
struct ParticipantAvatars {
    let roster: RosterModel

    func spec(for participant: BotThreadParticipant) -> BotAvatarSpec {
        if let profile = participant.localProfile, let bot = roster.bot(named: profile) { return bot.spec }
        let name = participant.localProfile ?? participant.key
        return BotAvatarSpec(name: name, uiMeta: Self.uiMeta(of: participant), photo: nil)
    }

    func accent(for participant: BotThreadParticipant) -> BotAccent? {
        if let profile = participant.localProfile, let bot = roster.bot(named: profile) { return bot.accent }
        return BotAccent(name: participant.localProfile ?? participant.key, uiMeta: Self.uiMeta(of: participant))
    }

    private static func uiMeta(of participant: BotThreadParticipant) -> [String: Any]? {
        guard let object = participant.avatar.uiMeta?.objectValue?.mapValues(\.foundationObject) else { return nil }
        return [BotAvatarMeta.uiMetaKey: object]
    }
}
