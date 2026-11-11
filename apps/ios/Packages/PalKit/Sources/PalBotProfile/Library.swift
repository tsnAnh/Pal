import Foundation
import PalProtocol

public enum LibraryFilter: String, CaseIterable, Sendable, Hashable {
    case all
    case media
    case links
    case files

    public var title: String {
        switch self {
        case .all: String(localized: "All")
        case .media: String(localized: "Media")
        case .links: String(localized: "Links")
        case .files: String(localized: "Files")
        }
    }
}

public enum LibraryEntryKind: String, Sendable, Hashable {
    case link
    case media
    case file
}

public struct LibraryEntry: Identifiable, Sendable, Hashable {
    public let id: String
    public let kind: LibraryEntryKind
    public let title: String
    public let kindLabel: String
    public let url: URL?
    public let assetRef: String?
    public let mime: String?
    public let occurredAt: Date
    public let cursor: String

    public var host: String? { url?.host(percentEncoded: false) }

    public var isOpenable: Bool {
        switch kind {
        case .link: url != nil
        case .media, .file: assetRef != nil || url != nil
        }
    }

    init?(_ wire: LibraryItemWire) {
        guard let kind = LibraryEntryKind(rawValue: wire.kind), let date = LibraryTimestamp.parse(wire.occurredAt) else { return nil }
        id = wire.id
        self.kind = kind
        title = wire.title
        kindLabel = wire.subtitle
        url = wire.url.flatMap(Self.webURL(_:))
        assetRef = wire.assetRef
        mime = wire.mime
        occurredAt = date
        cursor = wire.occurredAt
    }

    public init(
        id: String,
        kind: LibraryEntryKind,
        title: String,
        kindLabel: String,
        url: URL? = nil,
        assetRef: String? = nil,
        mime: String? = nil,
        occurredAt: Date,
        cursor: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.kindLabel = kindLabel
        self.url = url
        self.assetRef = assetRef
        self.mime = mime
        self.occurredAt = occurredAt
        self.cursor = cursor
    }

    public func subtitle(calendar: Calendar = .current, locale: Locale = .current) -> String {
        switch kind {
        case .link:
            return host ?? kindLabel
        case .media, .file:
            let day = occurredAt.formatted(.dateTime.month(.abbreviated).day().locale(locale))
            return "\(kindLabel) · \(day)"
        }
    }

    private static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil
        else { return nil }
        return url
    }
}

public struct LibraryPage: Sendable, Equatable {
    public var entries: [LibraryEntry]
    public var nextBefore: String?
    public var indexComplete: Bool
}

public enum LibrarySectionID: String, Sendable, Hashable {
    case thisWeek
    case older

    public var title: String {
        switch self {
        case .thisWeek: String(localized: "This week")
        case .older: String(localized: "Older")
        }
    }
}

public struct LibrarySection: Identifiable, Sendable, Equatable {
    public let id: LibrarySectionID
    public let entries: [LibraryEntry]
}

public enum LibraryGrouping {
    public static func sections(_ entries: [LibraryEntry], now: Date = Date(), calendar: Calendar = .current) -> [LibrarySection] {
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let recent = entries.filter { $0.occurredAt >= weekStart }
        let older = entries.filter { $0.occurredAt < weekStart }
        return [
            recent.isEmpty ? nil : LibrarySection(id: .thisWeek, entries: recent),
            older.isEmpty ? nil : LibrarySection(id: .older, entries: older),
        ].compactMap { $0 }
    }
}

enum LibraryTimestamp {
    static func parse(_ text: String) -> Date? {
        guard let dot = text.firstIndex(of: "."), let zone = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) else {
            return ISO8601DateFormatter().date(from: text)
        }
        let digits = text[text.index(after: dot)..<zone]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        let whole = ISO8601DateFormatter().date(from: String(text[..<dot]) + String(text[zone...]))
        guard let whole, let fraction = Double("0." + digits) else { return nil }
        return whole.addingTimeInterval(fraction)
    }
}

public struct LibraryService: Sendable {
    public static let pageSize = 50
    public static let previewLimit = 16_000_000

    private let gateway: BotsGateway

    public init(gateway: BotsGateway) {
        self.gateway = gateway
    }

    public func page(profile: String, filter: LibraryFilter, before: String? = nil) async throws -> LibraryPage {
        var params: [String: JSONValue] = ["kind": .string(filter.rawValue), "limit": .int(Self.pageSize)]
        if let before { params["before"] = .string(before) }
        do {
            let result = try await gateway.scoped("library.list", profile: profile, params)
            let wire = try gateway.decoded(LibraryListWire.self, result)
            return LibraryPage(entries: wire.items.compactMap(LibraryEntry.init), nextBefore: wire.nextBefore, indexComplete: wire.indexComplete)
        } catch {
            throw BotsError.surface(error)
        }
    }

    public func asset(profile: String, ref: String, thumbnail: Bool) async throws -> Data {
        do {
            let result = try await gateway.scoped("library.asset", profile: profile, [
                "asset_ref": .string(ref),
                "thumbnail": .bool(thumbnail),
                "max_bytes": .int(Self.previewLimit),
            ])
            let wire = try gateway.decoded(LibraryAssetWire.self, result)
            guard let data = Data(base64Encoded: wire.dataBase64), !data.isEmpty else { throw BotsError.invalidResponse }
            return data
        } catch {
            throw BotsError.surface(error)
        }
    }
}
