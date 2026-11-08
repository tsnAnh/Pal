import Foundation
import HermesProtocol

struct BotProfile: Decodable {
    struct Canonical: Decodable {
        var id: String?
        var resolvedId: String?
        var preview: String?
        var lastActive: Double?
    }

    var name: String
    var displayName: String?
    var isDefault: Bool?
    var canonicalSession: Canonical?
    var uiMeta: JSONValue?
    var hasAvatar: Bool?

    var uiMetaObject: [String: Any]? {
        guard let data = try? JSONEncoder().encode(uiMeta) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    var title: String {
        Self.title(name: name, displayName: displayName, uiMeta: uiMetaObject)
    }

    static func parse(_ values: [JSONValue]) -> [BotProfile] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return values.compactMap { try? $0.decoded(as: BotProfile.self, using: decoder) }
    }

    static func title(name: String, displayName: String?, uiMeta: [String: Any]?) -> String {
        let botMeta = uiMeta?["hermes-bots"] as? [String: Any]
        if let title = (botMeta?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let display = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !display.isEmpty {
            return display
        }
        let slug = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if slug.lowercased() == "default" { return "Hermes" }
        let words = slug.replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return words.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
