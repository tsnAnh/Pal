import PalDesign
import PalRoster
import SwiftUI

struct ActivityGlyph {
    let systemName: String
    let color: Color
    let label: LocalizedStringKey
}

extension BotActivity {
    var avatarMood: AvatarMood {
        switch self {
        case .working: .work
        case .offline, .idle, .needsInput: .idle
        }
    }

    var avatarOpacity: Double {
        self == .offline ? 0.45 : 1
    }

    var glyph: ActivityGlyph? {
        switch self {
        case .needsInput: ActivityGlyph(systemName: "checklist", color: .secondary, label: "Waiting for your answer")
        case .offline, .idle, .working: nil
        }
    }
}
