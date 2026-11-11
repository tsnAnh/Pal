import Foundation

public enum BotLookCatalog {
    public struct Swatch: Identifiable, Equatable, Sendable {
        public let hex: String
        public let name: String

        public var id: String { hex }
    }

    public static let shapes: [BlobKind] = [
        .round, .cloud, .boxy, .spark, .clover,
        .nub, .sun, .droplet, .capsule, .triangle,
        .gem, .burst, .hexagon,
    ]

    public static let shapeRows: [[BlobKind]] = [
        Array(shapes[0..<5]), Array(shapes[5..<10]), Array(shapes[10...]),
    ]

    public static let tealHex = "#0ec79b"

    public static let swatches: [Swatch] = [
        Swatch(hex: "#ffffff", name: "White"),
        Swatch(hex: "#845634", name: "Brown"),
        Swatch(hex: "#ed0a37", name: "Red"),
        Swatch(hex: "#f15105", name: "Vermilion"),
        Swatch(hex: "#f58a06", name: "Orange"),
        Swatch(hex: "#10dc69", name: "Green"),
        Swatch(hex: tealHex, name: "Teal"),
        Swatch(hex: "#1b7af8", name: "Blue"),
        Swatch(hex: "#833cf8", name: "Purple"),
        Swatch(hex: "#ee0d8f", name: "Pink"),
        Swatch(hex: "#6c6c6c", name: "Gray"),
    ]

    public static let swatchRows: [[Swatch]] = [Array(swatches[0..<6]), Array(swatches[6...])]

    public static let defaultShape: BlobKind = .boxy
    public static let defaultSwatch = swatches[4]

    public static func shapeString(seed: String, kind: BlobKind) -> String {
        "blobatar:\(seed):\(kind.rawValue)"
    }

    public static func displayName(of kind: BlobKind) -> String {
        switch kind {
        case .round: String(localized: "Round")
        case .organic: String(localized: "Organic")
        case .boxy: String(localized: "Squircle")
        case .capsule: String(localized: "Pill")
        case .nub: String(localized: "Bean")
        case .cloud: String(localized: "Cloud")
        case .droplet: String(localized: "Drop")
        case .hexagon: String(localized: "Hexagon")
        case .sun: String(localized: "Flower")
        case .triangle: String(localized: "Triangle")
        case .spark: String(localized: "Spark")
        case .clover: String(localized: "Clover")
        case .burst: String(localized: "Burst")
        case .gem: String(localized: "Gem")
        }
    }
}
