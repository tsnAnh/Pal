import Foundation

public struct ChatRowHeightRecord: Codable, Sendable, Equatable {
    public var id: String
    public var hash: UInt64
    public var height: Double

    public init(id: String, hash: UInt64, height: Double) {
        self.id = id
        self.hash = hash
        self.height = height
    }
}

public struct ChatRowHeightFile: Codable, Sendable, Equatable {
    public static let capacity = 400
    public static let layoutVersion = 1

    public var layout: Int
    public var width: Double
    public var textScale: String
    public var viewport: Double?
    public var rows: [ChatRowHeightRecord]

    public init(width: Double, textScale: String, viewport: Double? = nil, rows: [ChatRowHeightRecord]) {
        self.layout = Self.layoutVersion
        self.width = width
        self.textScale = textScale
        self.viewport = viewport
        var seen = Set<String>()
        var kept: [ChatRowHeightRecord] = []
        for row in rows.reversed() where row.height > 0 && row.height.isFinite {
            if seen.insert(row.id).inserted { kept.append(row) }
        }
        self.rows = Array(kept.reversed().suffix(Self.capacity))
    }

    public static func cacheName(forBot bot: String) -> String {
        "row-heights-" + bot
    }

    public func records(width queryWidth: Double, textScale queryScale: String) -> [String: ChatRowHeightRecord] {
        guard layout == Self.layoutVersion, abs(width - queryWidth) <= 0.5, textScale == queryScale else { return [:] }
        var result: [String: ChatRowHeightRecord] = [:]
        for row in rows { result[row.id] = row }
        return result
    }
}

public enum ChatRowFingerprint {
    public static func hash(_ parts: [String]) -> UInt64 {
        var value: UInt64 = 0xcbf29ce484222325
        for part in parts {
            for byte in part.utf8 {
                value ^= UInt64(byte)
                value = value &* 0x100000001b3
            }
            value ^= 0xFF
            value = value &* 0x100000001b3
        }
        return value
    }
}
