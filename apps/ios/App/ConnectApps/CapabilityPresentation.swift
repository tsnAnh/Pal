import PalBotProfile

extension CapabilityIndicator {
    var symbolName: String {
        switch self {
        case .on: "checkmark.circle.fill"
        case .limited: "exclamationmark.circle.fill"
        case .off: "circle"
        case .unavailable: "slash.circle"
        }
    }
}

extension CapabilityRow {
    var accessibilityIdentifier: String { "capabilityRow-\(id)" }

    var accessibilitySummary: String {
        [label, stateWord, reason].compactMap { $0 }.joined(separator: ", ")
    }
}
