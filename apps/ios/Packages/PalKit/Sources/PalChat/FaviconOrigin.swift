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

    public static func iconCandidates(inHTML html: String?, rootURL: URL) -> [URL] {
        let tagPattern = try! NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive])
        let relPattern = try! NSRegularExpression(pattern: "\\brel\\s*=\\s*[\"']([^\"']*)[\"']", options: [.caseInsensitive])
        let hrefPattern = try! NSRegularExpression(pattern: "\\bhref\\s*=\\s*[\"']([^\"']*)[\"']", options: [.caseInsensitive])
        let sizesPattern = try? NSRegularExpression(pattern: "\\bsizes\\s*=\\s*[\"']([^\"']*)[\"']", options: [.caseInsensitive])
        func capture(_ regex: NSRegularExpression, in text: String) -> String? {
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range), let captured = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[captured])
        }
        let page = html ?? ""
        var plain: [DeclaredIcon] = []
        var touch: [DeclaredIcon] = []
        for match in tagPattern.matches(in: page, range: NSRange(page.startIndex..., in: page)) {
            guard let tagRange = Range(match.range, in: page) else { continue }
            let tag = String(page[tagRange])
            guard let rel = capture(relPattern, in: tag)?.lowercased(), rel.contains("icon"), !rel.contains("mask-icon"),
                  let href = capture(hrefPattern, in: tag), let url = URL(string: href, relativeTo: rootURL)?.absoluteURL,
                  url.pathExtension.lowercased() != "svg"
            else { continue }
            let icon = DeclaredIcon(url: url, sizes: sizesPattern.flatMap { capture($0, in: tag) })
            if rel.contains("apple-touch-icon") {
                touch.append(icon)
            } else {
                plain.append(icon)
            }
        }
        let conventional = [URL(string: "/favicon.ico", relativeTo: rootURL)?.absoluteURL].compactMap { $0 }
        let preferred = largest(plain, limit: 3)
        let fallback = largest(touch, limit: 2)
        let ordered = preferred.isEmpty ? fallback + conventional : preferred + conventional + fallback
        var seen = Set<URL>()
        return ordered.filter { seen.insert($0).inserted }
    }

    private static func largest(_ icons: [DeclaredIcon], limit: Int) -> [URL] {
        icons.enumerated()
            .sorted { ($0.element.side, $1.offset) > ($1.element.side, $0.offset) }
            .prefix(limit)
            .map(\.element.url)
    }

    private struct DeclaredIcon {
        let url: URL
        let side: Int

        init(url: URL, sizes: String?) {
            self.url = url
            side = (sizes ?? "").lowercased().split(whereSeparator: \.isWhitespace)
                .compactMap { $0.split(separator: "x").first.flatMap { Int($0) } }
                .max() ?? 0
        }
    }
}
