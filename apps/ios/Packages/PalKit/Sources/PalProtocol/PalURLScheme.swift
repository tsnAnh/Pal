import Foundation

public enum PalURLScheme: String, Sendable, CaseIterable {
    case release = "dev.tsnanh.hermes.bot"
    case development = "dev.tsnanh.hermes.bot.dev"

    public static let infoKey = "PalURLScheme"

    public static let current = PalURLScheme(bundle: .main)

    public init(bundle: Bundle) {
        self = (bundle.object(forInfoDictionaryKey: Self.infoKey) as? String).flatMap(Self.init(rawValue:)) ?? .release
    }

    public var mcpRedirectURI: String { "\(rawValue):/mcp-oauth/callback" }

    public var wireParameters: [String: JSONValue] {
        self == .release ? [:] : ["app_scheme": .string(rawValue)]
    }
}
