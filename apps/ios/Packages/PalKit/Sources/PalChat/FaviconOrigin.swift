import Foundation

public enum FaviconOrigin {
    public static func host(of url: URL) -> String? {
        guard url.scheme?.lowercased() == "https", url.port == nil || url.port == 443,
              let host = url.host(percentEncoded: false)?.lowercased(), isPublicHostname(host)
        else { return nil }
        return host
    }

    public static func isPublicHostname(_ host: String) -> Bool {
        guard host.contains("."), host.count <= 253 else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".internal") || host.hasSuffix(".localhost") { return false }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) { return false }
        if host.contains(":") { return false }
        return true
    }

    public static func registrableSuffix(of host: String) -> String {
        host.split(separator: ".").suffix(2).joined(separator: ".")
    }

    public static func isSameSite(_ candidate: String, as host: String) -> Bool {
        let root = registrableSuffix(of: host)
        return candidate == host || candidate == root || candidate.hasSuffix("." + root)
    }

    public static func iconHref(inHTML html: String, rootURL: URL) -> URL? {
        let tagPattern = try! NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive])
        let relPattern = try! NSRegularExpression(pattern: "\\brel\\s*=\\s*[\"']([^\"']*)[\"']", options: [.caseInsensitive])
        let hrefPattern = try! NSRegularExpression(pattern: "\\bhref\\s*=\\s*[\"']([^\"']*)[\"']", options: [.caseInsensitive])
        func capture(_ regex: NSRegularExpression, in text: String) -> String? {
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range), let captured = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[captured])
        }
        let whole = NSRange(html.startIndex..., in: html)
        var fallback: URL?
        for match in tagPattern.matches(in: html, range: whole) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            guard let rel = capture(relPattern, in: tag)?.lowercased(), rel.contains("icon"),
                  let href = capture(hrefPattern, in: tag), let url = URL(string: href, relativeTo: rootURL)?.absoluteURL
            else { continue }
            if rel.contains("apple-touch-icon") {
                fallback = fallback ?? url
            } else {
                return url
            }
        }
        return fallback
    }
}
