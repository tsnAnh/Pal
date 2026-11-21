import Foundation

public enum ShopifyAddressError: Error, Sendable, Equatable {
    case empty
    case invalid
    case notSecure
    case credentials
    case port
    case wrongPath

    public var message: String {
        switch self {
        case .empty: String(localized: "Enter your store address, like your-store.myshopify.com.")
        case .invalid: String(localized: "That address doesn't look right. Use your store address, like your-store.myshopify.com.")
        case .notSecure: String(localized: "The address must start with https://, or have no prefix.")
        case .credentials: String(localized: "Remove the username and password from the address.")
        case .port: String(localized: "Leave off the port number.")
        case .wrongPath: String(localized: "Leave off everything after the store address. Pal adds the rest.")
        }
    }
}

public enum ShopifyConnector {
    public static let slug = "shopify"
    public static let name = "Shopify"
    public static let storeSuffix = ".myshopify.com"
    static let endpointPath = "/api/mcp"
    private static let maxHostLength = 253
    private static let maxLabelLength = 63

    public static func mcpURL(fromInput input: String) throws(ShopifyAddressError) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        let authority = try authority(of: Substring(trimmed))
        guard !authority.contains("@") else { throw .credentials }
        guard !authority.contains("[") else { throw .invalid }
        guard !authority.contains(":") else { throw .port }
        var host = authority.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { throw .invalid }
        if !host.contains(".") { host += storeSuffix }
        guard isHostname(host) else { throw .invalid }
        return "https://\(host)\(endpointPath)"
    }

    private static func authority(of input: Substring) throws(ShopifyAddressError) -> Substring {
        var rest = input
        if let marker = rest.range(of: "://") {
            guard rest[..<marker.lowerBound].lowercased() == "https" else { throw .notSecure }
            rest = rest[marker.upperBound...]
        }
        let end = rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex
        let path = rest[end...]
        guard path.isEmpty || path == "/" || path == endpointPath || path == endpointPath + "/" else { throw .wrongPath }
        return rest[..<end]
    }

    private static func isHostname(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.count <= maxHostLength, labels.count >= 2, let tld = labels.last,
              tld.count >= 2, tld.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= maxLabelLength && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}

extension ConnectApp {
    public var isShopify: Bool {
        if case .catalog(let entry) = source { entry.slug == ShopifyConnector.slug } else { false }
    }
}
