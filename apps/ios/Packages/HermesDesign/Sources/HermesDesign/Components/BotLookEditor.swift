import SwiftUI

public struct BotLook: Equatable, Sendable {
    public var seed: String
    public var kind: BlobKind
    public var colorHex: String

    public static let swatches: [String] = [
        "#ffffff", "#845634", "#ed0a37", "#f15105", "#f58a06", "#10dc69",
        "#0ec79b", "#1b7af8", "#833cf8", "#ee0d8f", "#6c6c6c",
    ]

    public static let defaultKind: BlobKind = .boxy
    public static let defaultColorHex = "#f58a06"

    public init(seed: String, kind: BlobKind, colorHex: String) {
        self.seed = seed
        self.kind = kind
        self.colorHex = colorHex
    }

    public init(name: String, shape: String?, color: String?) {
        let parsed = BlobShapeString.isBlob(shape) ? BlobShapeString.parse(shape, name: name) : nil
        seed = parsed?.seed ?? name
        kind = parsed?.kind ?? Self.defaultKind
        let meta = BotAvatarMeta(shape: shape, color: color, custom: true)
        colorHex = BotAccent(name: name, meta: meta)?.accentHex ?? Self.defaultColorHex
    }

    public var shapeString: String {
        "blobatar:\(seed):\(kind.rawValue)"
    }

    public var spec: BotAvatarSpec {
        BotAvatarSpec(name: seed, meta: BotAvatarMeta(shape: shapeString, color: colorHex, custom: true, imageKind: .shape))
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
        default: kind.rawValue.capitalized
        }
    }
}

public struct BotLookEditor: View {
    @Binding public var look: BotLook

    @Environment(\.hermesTheme) private var theme

    private static let shapeCell: CGFloat = 64
    private static let swatchCell: CGFloat = 44

    public init(look: Binding<BotLook>) {
        _look = look
    }

    private var swatches: [String] {
        BotLook.swatches.contains(look.colorHex.lowercased()) ? BotLook.swatches : [look.colorHex] + BotLook.swatches
    }

    public var body: some View {
        VStack(spacing: 22) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 5), spacing: 6) {
                ForEach(BlobKind.allCases, id: \.self) { kind in shapeCell(kind) }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 6), spacing: 6) {
                ForEach(swatches, id: \.self) { hex in swatchCell(hex) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("botLookEditor")
    }

    private func shapeCell(_ kind: BlobKind) -> some View {
        let isSelected = kind == look.kind
        var candidate = look
        candidate.kind = kind
        return Button { look.kind = kind } label: {
            BotAvatarView(spec: candidate.spec, size: 40, animated: false)
                .frame(width: Self.shapeCell, height: Self.shapeCell)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color(theme.palette.textPrimary), lineWidth: 2)
                            .frame(width: 54, height: 54)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(BotLook.displayName(of: kind)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("botShape-\(kind.rawValue)")
    }

    private func swatchCell(_ hex: String) -> some View {
        let isSelected = hex.lowercased() == look.colorHex.lowercased()
        let color = AvatarColor(css: hex)?.swiftUIColor ?? .gray
        return Button { look.colorHex = hex } label: {
            ZStack {
                Circle().fill(color).frame(width: 30, height: 30)
                if isSelected {
                    Circle().strokeBorder(Color(theme.palette.textPrimary), lineWidth: 2).frame(width: 40, height: 40)
                }
            }
            .frame(width: Self.swatchCell, height: Self.swatchCell)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(hex))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("botSwatch-\(hex.dropFirst())")
    }
}
