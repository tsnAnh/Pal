import Foundation

public enum BlobKind: String, CaseIterable, Sendable {
    case round, organic, boxy, capsule, nub, cloud, droplet, hexagon, sun, triangle
    case spark, clover, burst, gem

    var isExtended: Bool {
        switch self {
        case .spark, .clover, .burst, .gem: true
        default: false
        }
    }

    var traitPosition: Double {
        switch self {
        case .round: 0.11
        case .organic: 0.35
        case .boxy: 0.54
        case .capsule: 0.65
        case .nub: 0.745
        case .cloud: 0.825
        case .droplet: 0.8875
        case .hexagon: 0.9325
        case .sun: 0.965
        case .triangle: 0.99
        case .spark, .clover, .burst, .gem: 0.11
        }
    }
}

public enum ClassicShape: String, CaseIterable, Sendable {
    case circle, squircle, pill, triangle, hexagon, cloud, drop
    case blob, cube, pebble

    static let nameDerived: [ClassicShape] = [.circle, .squircle, .pill, .triangle, .hexagon, .cloud, .drop]

    init(stored: String) {
        switch stored {
        case "drop", "teardrop": self = .drop
        case "cloud": self = .cloud
        case "circle": self = .circle
        case "blob": self = .blob
        case "squircle": self = .squircle
        case "pill": self = .pill
        case "triangle", "tetrahedron", "wedge": self = .triangle
        case "hexagon", "hex", "icosahedron", "dodecahedron": self = .hexagon
        case "cube", "octahedron": self = .cube
        case "pebble": self = .pebble
        default: self = .circle
        }
    }
}

enum AvatarNaming {
    static let hueSaturation = 68
    static let hueLightness = 58

    static func profileColor(_ name: String?) -> String? {
        let key = JSCompat.trim(name ?? "")
        if key.isEmpty || key == "default" { return nil }
        let hue = JSCompat.hash31OverUTF16(key) % 360
        return "hsl(\(hue) \(hueSaturation)% \(hueLightness)%)"
    }

    static func defaultShape(for name: String) -> ClassicShape {
        let hash = JSCompat.hash31OverCodePoints(name)
        return ClassicShape.nameDerived[Int(hash) % ClassicShape.nameDerived.count]
    }

    static func avatarColor(_ meta: AvatarColor?, name: String) -> AvatarColor {
        meta ?? AvatarColor(css: profileColor(name)) ?? .primary
    }
}

enum BlobShapeString {
    struct Parsed: Equatable, Sendable {
        var seed: String
        var seedPart: String
        var kind: BlobKind?
    }

    static let defaultSeed = "agent"

    static func isBlob(_ shape: String?) -> Bool {
        guard let shape else { return false }
        return shape == "blobatar" || shape.hasPrefix("blobatar:")
    }

    static func parse(_ shape: String?, name: String?) -> Parsed {
        let parts = (shape ?? "").split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let seedPart = parts.count > 1 ? parts[1] : ""
        let kind = parts.count > 2 ? BlobKind(rawValue: parts[2]) : nil
        let fallback = (name?.isEmpty == false ? name : nil) ?? defaultSeed
        return Parsed(seed: seedPart.isEmpty ? fallback : seedPart, seedPart: seedPart, kind: kind)
    }
}
