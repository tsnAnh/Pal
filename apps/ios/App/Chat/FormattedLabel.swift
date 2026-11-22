import Foundation

@MainActor
enum FormattedLabel {
    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 256
        return cache
    }()

    static func list(_ names: [String]) -> String {
        cached(kind: "list", key: names.joined(separator: "\u{1F}")) { names.formatted(.list(type: .and)) }
    }

    static func nextRun(_ date: Date) -> String {
        cached(kind: "next-run", key: String(date.timeIntervalSince1970)) {
            date.formatted(date: .abbreviated, time: .shortened)
        }
    }

    private static func cached(kind: String, key: String, format: () -> String) -> String {
        let entry = "\(kind)|\(Locale.current.identifier)|\(TimeZone.current.identifier)|\(key)" as NSString
        if let hit = cache.object(forKey: entry) { return hit as String }
        let text = format()
        cache.setObject(text as NSString, forKey: entry)
        return text
    }
}
