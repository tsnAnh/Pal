import Foundation
import PalChat

extension ParsedMarkdown {
    nonisolated(unsafe) private static let cache: NSCache<NSString, ParsedMarkdownBox> = {
        let cache = NSCache<NSString, ParsedMarkdownBox>()
        cache.countLimit = 512
        return cache
    }()

    static func cached(_ source: String) -> ParsedMarkdown {
        let key = source as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let parsed = ParsedMarkdown(source: source, document: MarkdownDocument(parsing: source))
        cache.setObject(ParsedMarkdownBox(parsed), forKey: key)
        return parsed
    }
}

private final class ParsedMarkdownBox {
    let value: ParsedMarkdown

    init(_ value: ParsedMarkdown) {
        self.value = value
    }
}
