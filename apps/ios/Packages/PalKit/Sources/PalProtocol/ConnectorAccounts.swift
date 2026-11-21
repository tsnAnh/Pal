import Foundation

public enum ConnectorAccountNameError: Sendable, Equatable, CaseIterable {
    case empty
    case tooLong
    case invalidCharacter
    case leadingHyphen
    case taken

    public var message: String {
        switch self {
        case .empty: String(localized: "Give this account a name.")
        case .tooLong: String(localized: "Use 32 characters or fewer.")
        case .invalidCharacter: String(localized: "Use only lowercase letters, numbers and hyphens.")
        case .leadingHyphen: String(localized: "Start with a letter or a number.")
        case .taken: String(localized: "You already have an account with that name.")
        }
    }
}

public enum ConnectorAccountName {
    public static let maxLength = 32
    public static let defaultName = "default"

    private static let suggestions = ["default", "work", "personal"]

    public static func validate(_ name: String, existing: [String] = []) -> ConnectorAccountNameError? {
        if name.isEmpty { return .empty }
        if name.count > maxLength { return .tooLong }
        if name.hasPrefix("-") { return .leadingHyphen }
        if !name.unicodeScalars.allSatisfy(isAllowed) { return .invalidCharacter }
        return existing.contains(name) ? .taken : nil
    }

    public static func isValid(_ name: String) -> Bool {
        validate(name) == nil
    }

    public static func suggest(existing: [String]) -> String {
        let taken = Set(existing)
        if let name = suggestions.first(where: { !taken.contains($0) }) { return name }
        var number = 2
        while taken.contains("account-\(number)") { number += 1 }
        return "account-\(number)"
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x61...0x7A, 0x2D: true
        default: false
        }
    }
}

public struct McpServiceID: Sendable, Hashable {
    public static let prefix = "mcp:"

    public var slug: String
    public var account: String?

    public init(slug: String, account: String?) {
        self.slug = slug
        self.account = account
    }

    public init?(service: String) {
        guard service.hasPrefix(Self.prefix) else { return nil }
        let parts = service.dropFirst(Self.prefix.count).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard let slug = parts.first, !slug.isEmpty, parts.count <= 2 else { return nil }
        if parts.count == 2 {
            guard ConnectorAccountName.isValid(parts[1]) else { return nil }
            self.init(slug: slug, account: parts[1])
        } else {
            self.init(slug: slug, account: nil)
        }
    }

    public var service: String {
        Self.prefix + slug + (account.map { ":\($0)" } ?? "")
    }

    public func displayTitle(vendor: String) -> String {
        guard let account else { return vendor }
        let suffix = "(\(account))"
        return vendor.hasSuffix(suffix) ? vendor : "\(vendor) \(suffix)"
    }
}
