import Foundation
import PalProtocol

public struct VaultLoginDraft: Sendable, Equatable {
    public var label: String
    public var website: String
    public var identifier: String
    public var password: String

    public init(label: String = "", website: String = "", identifier: String = "", password: String = "") {
        self.label = label
        self.website = website
        self.identifier = identifier
        self.password = password
    }

    public var trimmedLabel: String { label.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var trimmedIdentifier: String { identifier.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var normalizedOrigin: String? {
        let raw = website.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let candidate = raw.contains("://") ? raw : "https://\(raw)"
        guard let components = URLComponents(string: candidate), let host = components.host, !host.isEmpty,
              ["http", "https"].contains(components.scheme?.lowercased() ?? "")
        else { return nil }
        return candidate
    }

    public var identifierType: String {
        let value = trimmedIdentifier
        if value.contains("@") { return "email" }
        let phoneCharacters = CharacterSet(charactersIn: "+-() 0123456789")
        if !value.isEmpty, value.unicodeScalars.allSatisfy(phoneCharacters.contains) { return "phone" }
        return "username"
    }

    public var isComplete: Bool {
        !trimmedLabel.isEmpty && normalizedOrigin != nil && !trimmedIdentifier.isEmpty && !password.isEmpty
    }
}

public struct VaultAPIKeyDraft: Sendable, Equatable {
    public var label: String
    public var apiKey: String

    public init(label: String = "", apiKey: String = "") {
        self.label = label
        self.apiKey = apiKey
    }

    public var trimmedLabel: String { label.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var isComplete: Bool { !trimmedLabel.isEmpty && !apiKey.isEmpty }
}

public struct VaultEditDraft: Sendable, Equatable {
    public let id: String
    public let kind: VaultEntry.Kind
    public var label: String
    public var website: String
    public var identifier: String
    public var secret: String

    public init(entry: VaultEntry) {
        id = entry.id
        kind = entry.kind
        label = entry.title
        website = entry.origin ?? ""
        identifier = entry.identifier ?? ""
        secret = ""
    }

    public var trimmedLabel: String { label.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var trimmedIdentifier: String { identifier.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var normalizedOrigin: String? { VaultLoginDraft(website: website).normalizedOrigin }
    public var identifierType: String { VaultLoginDraft(identifier: identifier).identifierType }

    public var isComplete: Bool {
        guard !trimmedLabel.isEmpty else { return false }
        return kind == .login ? normalizedOrigin != nil && !trimmedIdentifier.isEmpty : true
    }
}

public struct VaultEntry: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case login
        case apiKey = "api_key"
        case payment
        case address
        case other

        public var symbolName: String {
            switch self {
            case .login: "key"
            case .apiKey: "key.horizontal"
            case .payment: "creditcard"
            case .address: "person.text.rectangle"
            case .other: "lock"
            }
        }
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let subtitle: String?
    public let origin: String?
    public let identifier: String?
    public let isRemovable: Bool

    public var isEditable: Bool { isRemovable && kind != .other }

    public init(_ item: SettingsWire.VaultItem) {
        id = item.id
        kind = Kind(rawValue: item.kind) ?? .other
        title = item.label
        origin = item.origin
        identifier = item.identifier
        isRemovable = (item.backend ?? "local") == "local"
        subtitle = Self.subtitle(for: item)
    }

    private static func subtitle(for item: SettingsWire.VaultItem) -> String? {
        if item.kind == Kind.apiKey.rawValue { return nil }
        let origin = item.origin.flatMap { URL(string: $0)?.host(percentEncoded: false) ?? $0 }
        let parts = [item.identifier, origin].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
