import HermesDesign
import HermesRoster
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
        case .offline, .idle, .needsInput, .attention: .idle
        }
    }

    var avatarOpacity: Double {
        self == .offline ? 0.45 : 1
    }

    var glyph: ActivityGlyph? {
        switch self {
        case .needsInput: ActivityGlyph(systemName: "checklist", color: .secondary, label: "Waiting for your answer")
        case .attention: ActivityGlyph(systemName: "exclamationmark.circle.fill", color: .orange, label: "Needs your attention")
        case .offline, .idle, .working: nil
        }
    }
}
