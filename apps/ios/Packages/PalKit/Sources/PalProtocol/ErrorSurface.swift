import Foundation

public struct ErrorSurface: Codable, Sendable, Hashable {
    public static let noProviderConfigured = "no_provider_configured"
    public static let failedTurnKind = "failed_turn"

    public var code: String

    public init(code: String) {
        self.code = code
    }

    public init?(metadata: JSONValue?) {
        guard let code = metadata?["error_surface"]?["code"]?.stringValue, !code.isEmpty else { return nil }
        self.code = code
    }

    public var needsModelProvider: Bool { code == Self.noProviderConfigured }
}

public extension MessageComplete {
    var needsModelProvider: Bool { errorSurface?.needsModelProvider == true }
}

public extension InboundRowWire {
    var isFailedTurnNeedingModelProvider: Bool {
        displayKind == ErrorSurface.failedTurnKind && ErrorSurface(metadata: displayMetadata)?.needsModelProvider == true
    }
}
