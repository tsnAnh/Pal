import Foundation

public enum PreviewKind: Sendable, Equatable {
    case plain
    case fromBot(handle: String)
}

public struct PreviewSender: Sendable, Equatable {
    public var name: String
    public var displayName: String

    public init(name: String, displayName: String) {
        self.name = name
        self.displayName = displayName
    }
}

public struct ClassifiedPreview: Sendable, Equatable {
    public var kind: PreviewKind
    public var text: String

    public init(kind: PreviewKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public enum PreviewClassifier {
    public static let primaryHandle = "hermes"
    public static let primaryName = "default"
    static let emptyBody = "…"

    private static var sender: Regex<(Substring, Substring?, Substring?)> { /^Message from (?:agent '([^']+)'|🤖\s*([^\s(@]+))/.ignoresCase() }
    private static var deliveryPrefix: Regex<Substring> { /^Message from (?:agent '[^']+'|🤖[^:]+):\s*/.ignoresCase() }
    private static var statedSender: Regex<(Substring, Substring, Substring)> { /^Message from 🤖\s*(.+?)\s*\(@([A-Za-z0-9_-]+)\)\s*:/.ignoresCase() }

    public static func kind(of preview: String?) -> PreviewKind {
        let text = (preview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let captured = capturedSender(in: text) else { return .plain }
        return .fromBot(handle: handle(forProfile: captured.token, known: []))
    }

    public static func classify(_ preview: String?, senders: [PreviewSender] = []) -> ClassifiedPreview {
        let text = (preview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let captured = capturedSender(in: text) else { return ClassifiedPreview(kind: .plain, text: text) }
        let profile = profileName(forHandle: captured.token, known: senders)
        let known = senders.first { $0.name == profile }?.displayName
        let display = known ?? captured.statedName ?? captured.token
        let body = text.replacing(deliveryPrefix, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPrefix = text.firstMatch(of: deliveryPrefix) != nil
        let shown = hasPrefix ? (body.isEmpty ? emptyBody : body) : text
        return ClassifiedPreview(
            kind: .fromBot(handle: handle(forProfile: captured.token, known: senders)),
            text: hasPrefix ? "Message from \(display): \(shown)" : text
        )
    }

    private struct Captured {
        var token: String
        var statedName: String?
    }

    private static func capturedSender(in text: String) -> Captured? {
        guard !text.isEmpty, let match = text.firstMatch(of: sender) else { return nil }
        let first = (match.1 ?? match.2).map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !first.isEmpty else { return nil }
        if match.2 != nil, let stated = text.firstMatch(of: statedSender) {
            return Captured(token: String(stated.2).lowercased(), statedName: String(stated.1))
        }
        return Captured(token: first, statedName: nil)
    }

    private static func handle(forProfile name: String, known: [PreviewSender]) -> String {
        name == primaryName && !known.contains(where: { $0.name == primaryHandle }) ? primaryHandle : name
    }

    private static func profileName(forHandle handle: String, known: [PreviewSender]) -> String {
        if known.contains(where: { $0.name == handle }) { return handle }
        return handle == primaryHandle ? primaryName : handle
    }
}
