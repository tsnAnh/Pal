import Foundation

public struct BotLook: Equatable, Sendable {
    public var seed: String
    public var kind: BlobKind
    public var colorHex: String

    public init(seed: String, kind: BlobKind, colorHex: String) {
        self.seed = seed
        self.kind = kind
        self.colorHex = colorHex
    }

    public init(name: String, shape: String?, color: String?) {
        let parsed = BlobShapeString.isBlob(shape) ? BlobShapeString.parse(shape, name: name) : nil
        seed = parsed?.seed ?? name
        kind = parsed?.kind ?? BotLookCatalog.defaultShape
        let meta = BotAvatarMeta(shape: shape, color: color, custom: true)
        colorHex = BotAccent(name: name, meta: meta)?.accentHex ?? BotLookCatalog.defaultSwatch.hex
    }

    public var shapeString: String {
        BotLookCatalog.shapeString(seed: seed, kind: kind)
    }

    public var spec: BotAvatarSpec {
        BotAvatarSpec(name: seed, meta: BotAvatarMeta(shape: shapeString, color: colorHex, custom: true, imageKind: .shape))
    }
}
