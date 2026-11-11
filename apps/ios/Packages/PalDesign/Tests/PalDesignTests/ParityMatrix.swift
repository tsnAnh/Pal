import Foundation

struct ParityMatrix: Decodable {
    struct Meta: Decodable {
        var shape: String?
        var color: String?
        var custom: Bool?
        var image: String?
        var imageKind: String?
    }

    struct Resolved: Decodable {
        var kind: String
        var shape: String
        var color: String
        var appearanceColor: String?
        var hasImage: Bool
        var seed: String?
        var pinnedKind: String?
        var customBody: Bool?
        var headFill: String?
        var eyeFill: String?
    }

    struct Case: Decodable {
        var id: String
        var group: String
        var name: String
        var meta: Meta
        var mood: String
        var render: Bool
        var resolved: Resolved
        var png: String?
    }

    struct ColorGolden: Decodable {
        var input: String
        var safe: String?
        var dark: Bool?
        var eye: String?
        var hex: String?
    }

    struct NameGolden: Decodable {
        var name: String
        var profileColor: String?
        var defaultShape: String
    }

    struct ShapeGolden: Decodable {
        var shape: String
        var name: String
        var isBlob: Bool
        var seed: String
        var seedPart: String
        var kind: String
    }

    struct FigureGolden: Decodable {
        var seed: String
        var shapeTrait: Double?
        var silhouette: String
        var svg: String
    }

    struct AccentGolden: Decodable {
        struct AccentMeta: Decodable {
            var color: String?
            var custom: Bool?
        }

        var name: String
        var meta: AccentMeta
        var resolved: String
        var accent: String?
        var foreground: String?
    }

    var size: Int
    var kindTraits: [String: Double]
    var cases: [Case]
    var colors: [ColorGolden]
    var names: [NameGolden]
    var shapes: [ShapeGolden]
    var accents: [AccentGolden]

    static let figures: [FigureGolden] = load("figures")

    static let shared: ParityMatrix = load("matrix")

    private static func load<Value: Decodable>(_ name: String) -> Value {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Parity") else {
            fatalError("Parity/\(name).json missing from test bundle; run apps/ios/Tools/avatar-parity/regenerate.sh")
        }
        do {
            return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
        } catch {
            fatalError("Parity/\(name).json unreadable: \(error)")
        }
    }

    static func pngURL(_ name: String) -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Parity") else {
            fatalError("Parity/\(name) missing from test bundle")
        }
        return url
    }
}

extension ParityMatrix.Case {
    var uiMeta: [String: Any] {
        var dict: [String: Any] = [:]
        if let shape = meta.shape { dict["shape"] = shape }
        if let color = meta.color { dict["color"] = color }
        if let custom = meta.custom { dict["custom"] = custom }
        if let image = meta.image { dict["image"] = image }
        if let imageKind = meta.imageKind { dict["imageKind"] = imageKind }
        return ["hermes-bots": dict]
    }
}
