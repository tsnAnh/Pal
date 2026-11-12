import Foundation

public struct PastedCallback: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let maxLength = 4096

    public let value: String

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maxLength else { return nil }
        value = trimmed
    }

    public var description: String { "PastedCallback(redacted)" }
    public var debugDescription: String { description }
}
