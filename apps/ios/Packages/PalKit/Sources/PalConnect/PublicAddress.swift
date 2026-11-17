import Foundation

public enum PublicAddress {
    public enum Problem: String, Sendable, Equatable, CaseIterable {
        case tooLong = "too_long"
        case invalid
        case notHTTPS = "not_https"
        case userinfo
        case ipHost = "ip_host"
        case invalidHost = "invalid_host"
        case path
        case queryOrFragment = "query_or_fragment"

        public var message: String {
            switch self {
            case .tooLong: String(localized: "That address is too long.")
            case .invalid: String(localized: "That doesn't look like a web address.")
            case .notHTTPS: String(localized: "The address must start with https://")
            case .userinfo: String(localized: "Remove the user name and password.")
            case .ipHost: String(localized: "Use a domain name, not an IP address.")
            case .invalidHost: String(localized: "Use a full domain name, like pal.example.com.")
            case .path, .queryOrFragment: String(localized: "Remove everything after the domain name.")
            }
        }
    }

    public enum Verdict: Sendable, Equatable {
        case clear
        case address(String)
        case refused(Problem)
    }

    static let maxLength = 255

    public static func evaluate(_ raw: String) -> Verdict {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.unicodeScalars.count > maxLength { return .refused(.tooLong) }
        if value.isEmpty { return .clear }
        let blocked = CharacterSet.whitespacesAndNewlines.union(.controlCharacters).union(CharacterSet(charactersIn: "\"'<>\\"))
        if value.unicodeScalars.contains(where: blocked.contains) { return .refused(.invalid) }
        guard let schemeEnd = value.firstIndex(of: ":"), value[..<schemeEnd].lowercased() == "https" else { return .refused(.notHTTPS) }
        let rest = value[value.index(after: schemeEnd)...]
        guard rest.hasPrefix("//") else { return .refused(.invalid) }
        let afterSlashes = rest.dropFirst(2)
        let authorityEnd = afterSlashes.firstIndex { "/?#".contains($0) } ?? afterSlashes.endIndex
        let authority = afterSlashes[..<authorityEnd]
        if authority.contains("@") { return .refused(.userinfo) }
        if value.contains("?") || value.contains("#") { return .refused(.queryOrFragment) }
        let path = afterSlashes[authorityEnd...]
        if !path.isEmpty, path != "/" { return .refused(.path) }
        return host(of: authority)
    }

    private static func host(of authority: Substring) -> Verdict {
        var name = authority
        var port: Int?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return .refused(.invalid) }
            let inside = authority[authority.index(after: authority.startIndex)..<close]
            let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.")
            return inside.contains(":") && inside.unicodeScalars.allSatisfy(hex.contains) ? .refused(.ipHost) : .refused(.invalid)
        }
        if let colon = authority.lastIndex(of: ":") {
            name = authority[..<colon]
            let digits = authority[authority.index(after: colon)...]
            if !digits.isEmpty {
                guard digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber), let number = Int(digits), (1...65535).contains(number)
                else { return .refused(.invalid) }
                port = number
            }
        }
        var host = name.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        if isIPv4(host) { return .refused(.ipHost) }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, host.count <= 253, labels.allSatisfy(isLabel) else { return .refused(.invalidHost) }
        return .address("https://" + host + (port.map { ":\($0)" } ?? ""))
    }

    private static func isLabel(_ label: Substring) -> Bool {
        guard (1...63).contains(label.count), label.first != "-", label.last != "-" else { return false }
        return label.unicodeScalars.allSatisfy { (97...122).contains($0.value) || (48...57).contains($0.value) || $0.value == 45 }
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            part.allSatisfy { $0.isASCII && $0.isNumber } && !part.isEmpty && (part == "0" || !part.hasPrefix("0")) && Int(part).map { $0 <= 255 } == true
        }
    }
}
