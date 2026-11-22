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
        .gem, .burst, .hexagon, .heart,
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

    private static let displayNames: [BlobKind: String.LocalizationValue] = [
        .round: "Round", .organic: "Organic", .boxy: "Squircle", .capsule: "Pill", .nub: "Bean",
        .cloud: "Cloud", .droplet: "Drop", .hexagon: "Hexagon", .sun: "Flower", .triangle: "Triangle",
        .spark: "Spark", .clover: "Clover", .burst: "Burst", .gem: "Gem", .heart: "Heart",
    ]

    public static func displayName(of kind: BlobKind) -> String {
        String(localized: displayNames[kind] ?? String.LocalizationValue(kind.rawValue))
    }
}

public enum LookDirection: Sendable {
    case left, right, up, down
}

public extension BotLookCatalog {
    static let shapeRowLengths = shapeRows.map(\.count)
    static let swatchRowLengths = swatchRows.map(\.count)

    static func move(_ index: Int, _ direction: LookDirection, rowLengths: [Int]) -> Int {
        let total = rowLengths.reduce(0, +)
        guard total > 0 else { return 0 }
        let index = min(max(index, 0), total - 1)
        var rowStart = 0
        var row = 0
        while index >= rowStart + rowLengths[row] {
            rowStart += rowLengths[row]
            row += 1
        }
        let column = index - rowStart
        switch direction {
        case .left:
            return rowStart + max(column - 1, 0)
        case .right:
            return rowStart + min(column + 1, rowLengths[row] - 1)
        case .up:
            guard row > 0 else { return index }
            let previousStart = rowStart - rowLengths[row - 1]
            return previousStart + min(column, rowLengths[row - 1] - 1)
        case .down:
            guard row < rowLengths.count - 1 else { return index }
            return rowStart + rowLengths[row] + min(column, rowLengths[row + 1] - 1)
        }
    }

    static func shapeAccessibilityLabel(_ kind: BlobKind, isSelected: Bool) -> String {
        let position = (shapes.firstIndex(of: kind) ?? 0) + 1
        let base = String(localized: "Shape \(position) of \(shapes.count), \(displayName(of: kind))")
        return isSelected ? String(localized: "\(base), selected") : base
    }

    static func swatchAccessibilityLabel(_ swatch: Swatch, isSelected: Bool) -> String {
        let position = (swatches.firstIndex(of: swatch) ?? 0) + 1
        let name = String(localized: String.LocalizationValue(swatch.name))
        let base = String(localized: "Colour \(name), \(position) of \(swatches.count)")
        return isSelected ? String(localized: "\(base), selected") : base
    }
}

public extension BotLookCatalog {
    static func prepareLooks(seed: String) {
        let previewOrder = [defaultShape] + shapes.filter { $0 != defaultShape }
        let solids = previewOrder.compactMap { kind -> AvatarSolid? in
            let spec = BotAvatarSpec(name: seed, meta: BotAvatarMeta(shape: shapeString(seed: seed, kind: kind), color: defaultSwatch.hex, custom: true))
            guard case .solid(let solid) = AvatarContent(spec) else { return nil }
            return solid
        }
        for solid in solids { _ = solid.detailed(for: PalMetrics.createPreviewFrame) }
    }
}
