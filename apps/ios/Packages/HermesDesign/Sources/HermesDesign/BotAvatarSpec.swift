import Foundation

public struct BotAvatarMeta: Equatable, Sendable {
    public enum ImageKind: String, Sendable {
        case photo
        case shape
    }

    public var shape: String?
    public var color: String?
    public var custom: Bool
    public var image: String?
    public var imageKind: ImageKind?

    public init(
        shape: String? = nil,
        color: String? = nil,
        custom: Bool = false,
        image: String? = nil,
        imageKind: ImageKind? = nil
    ) {
        self.shape = shape
        self.color = color
        self.custom = custom
        self.image = image
        self.imageKind = imageKind
    }

    public init(uiMeta: [String: Any]?) {
        let dictionary = uiMeta?[Self.uiMetaKey] as? [String: Any] ?? [:]
        self.init(
            shape: (dictionary["shape"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            color: dictionary["color"] as? String,
            custom: Self.boolean(dictionary["custom"]),
            image: (dictionary["image"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            imageKind: (dictionary["imageKind"] as? String).flatMap(ImageKind.init(rawValue:))
        )
    }

    public static let uiMetaKey = "hermes-bots"

    private static func boolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }
}

public struct BlobAvatar: Equatable, Sendable {
    public enum Body: Equatable, Sendable {
        case seedPalette
        case custom(AvatarColor)
    }

    public let seed: String
    public let kind: BlobKind?
    public let body: Body

    public var isCustomBody: Bool {
        if case .custom = body { return true }
        return false
    }

    public var headFillCSS: String {
        headFill(palette: BlobFigure(seed: seed, kind: kind).palette).css
    }

    public var eyeFillCSS: String {
        headFill(palette: BlobFigure(seed: seed, kind: kind).palette).eyeFillCSS
    }

    func headFill(palette: BlobPalette.Colors) -> AvatarColor {
        switch body {
        case .custom(let color): color
        case .seedPalette: AvatarColor(css: palette.head) ?? .primary
        }
    }
}

public struct ClassicAvatar: Equatable, Sendable {
    public let shape: ClassicShape
    public let color: AvatarColor

    public var eyeFillCSS: String { color.eyeFillCSS }
}

public struct SigilAvatar: Equatable, Sendable {
    public let name: String
    public let seed: Int
    public let color: AvatarColor
}

public enum ShapeAvatar: Equatable, Sendable {
    case blob(BlobAvatar)
    case classic(ClassicAvatar)
    case sigil(SigilAvatar)
}

public struct PhotoAvatar: Equatable, Sendable {
    public let data: Data
    public let fallback: ShapeAvatar
}

public enum BotAvatarSpec: Equatable, Sendable {
    case photo(PhotoAvatar)
    case shape(ShapeAvatar)

    public var isPhoto: Bool {
        if case .photo = self { return true }
        return false
    }
}

extension BotAvatarSpec {
    public static let primaryName = "default"

    public init(name: String, uiMeta: [String: Any]?, photo: Data? = nil) {
        self.init(name: name, meta: BotAvatarMeta(uiMeta: uiMeta), photo: photo)
    }

    public init(name: String, meta: BotAvatarMeta, photo: Data? = nil) {
        let shape = Self.shapeAvatar(name: name, meta: meta)
        if meta.imageKind == .photo, let data = Self.photoData(meta: meta, supplied: photo) {
            self = .photo(PhotoAvatar(data: data, fallback: shape))
        } else {
            self = .shape(shape)
        }
    }

    private static func isPrimary(_ name: String) -> Bool {
        JSCompat.lowercased(JSCompat.trim(name)) == primaryName
    }

    static func resolvedColor(name: String, meta: BotAvatarMeta) -> AvatarColor {
        if isPrimary(name), !meta.custom { return .primary }
        return AvatarNaming.avatarColor(AvatarColor(css: meta.color), name: name)
    }

    static func shapeAvatar(name: String, meta: BotAvatarMeta) -> ShapeAvatar {
        let usesPrimaryLook = isPrimary(name) && !meta.custom
        let storedShape = usesPrimaryLook
            ? ClassicShape.squircle.rawValue
            : meta.shape ?? AvatarNaming.defaultShape(for: name).rawValue
        let color = resolvedColor(name: name, meta: meta)

        if BlobShapeString.isBlob(storedShape) {
            let parsed = BlobShapeString.parse(storedShape, name: name)
            let usesSeedPalette = color.css == AvatarNaming.profileColor(name)
            return .blob(BlobAvatar(
                seed: parsed.seed, kind: parsed.kind, body: usesSeedPalette ? .seedPalette : .custom(color)
            ))
        }

        if storedShape.hasPrefix("sigil-") {
            let seed = integerSeed(String(storedShape.dropFirst("sigil-".count)))
            return .sigil(SigilAvatar(name: name, seed: seed, color: color))
        }

        return .classic(ClassicAvatar(shape: ClassicShape(stored: storedShape), color: color))
    }

    private static let maxExactInteger = Double(1 << 53)
    private static let decimalLiteral = try! NSRegularExpression(pattern: "\\A[+-]?(?:[0-9]+\\.?[0-9]*|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?\\z")

    static func integerSeed(_ text: String) -> Int {
        let trimmed = JSCompat.trim(text)
        if trimmed.isEmpty { return 0 }
        let lowered = trimmed.lowercased()
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where lowered.hasPrefix(prefix) {
            return Int(lowered.dropFirst(2), radix: radix).flatMap { $0 >= 0 ? $0 : nil } ?? 0
        }
        if let integer = Int(trimmed), abs(Double(integer)) < maxExactInteger { return integer }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard decimalLiteral.firstMatch(in: trimmed, range: range) != nil,
              let value = Double(trimmed), value.isFinite, value == value.rounded(), abs(value) < maxExactInteger
        else { return 0 }
        return Int(value)
    }

    private static func photoData(meta: BotAvatarMeta, supplied: Data?) -> Data? {
        if let supplied, !supplied.isEmpty { return supplied }
        guard let image = meta.image, image.hasPrefix("data:"), let comma = image.firstIndex(of: ",") else { return nil }
        let header = image[image.startIndex..<comma]
        guard header.hasSuffix(";base64") else { return nil }
        let payload = String(image[image.index(after: comma)...])
        guard let data = Data(base64Encoded: payload), !data.isEmpty else { return nil }
        return data
    }
}
