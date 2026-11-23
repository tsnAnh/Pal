import Foundation
import PalBotProfile

extension CapabilityIndicator {
    var symbolName: String {
        switch self {
        case .on: "checkmark"
        case .limited: "exclamationmark.circle"
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

extension CapabilityGroup {
    var title: String {
        switch kind {
        case .needsKey: String(localized: "Needs a key")
        case .on: String(localized: "On")
        case .off: rows.allSatisfy { $0.indicator == .unavailable } ? String(localized: "Unavailable") : String(localized: "Off")
        }
    }

    var identifierSuffix: String {
        switch kind {
        case .needsKey: "needsKey"
        case .on: "on"
        case .off: "off"
        }
    }
}
