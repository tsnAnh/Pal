import Foundation
import PalProtocol

public struct MemoryImportSummary: Sendable, Equatable {
    public let text: String
    public let added: Int

    public init(_ outcome: SettingsWire.MemoryImport) {
        added = outcome.added
        var parts = [outcome.added == 1 ? "Added 1 memory." : "Added \(outcome.added) memories."]
        let skipped = outcome.duplicates + outcome.tooLong + outcome.blocked + outcome.overBudget
        if outcome.duplicates > 0 { parts.append("\(outcome.duplicates) already remembered.") }
        if outcome.tooLong > 0 { parts.append("\(outcome.tooLong) too long.") }
        if outcome.blocked > 0 { parts.append("\(outcome.blocked) not allowed.") }
        if outcome.overBudget > 0 { parts.append("\(outcome.overBudget) did not fit in memory.") }
        if outcome.added == 0, skipped == 0 { parts = ["Nothing to import."] }
        text = parts.joined(separator: " ")
    }
}
