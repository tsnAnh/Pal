import PalChat
import SwiftUI

extension RosterModel {
    func heldDraftBots(for profile: String? = nil) -> [HeldDraftBot] {
        bots
            .filter { profile == nil || $0.name == profile }
            .map { HeldDraftBot(name: $0.name, displayName: $0.displayName) }
    }
}

extension EnvironmentValues {
    @Entry var heldDrafts: HeldDraftsModel?
}
