import SwiftUI

public struct BotLookPicker: View {
    @Binding public var shape: BlobKind
    @Binding public var colorHex: String
    public let seed: String

    @Environment(\.hermesTheme) private var theme

    public init(shape: Binding<BlobKind>, colorHex: Binding<String>, seed: String) {
        _shape = shape
        _colorHex = colorHex
        self.seed = seed
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ForEach(Array(BotLookCatalog.shapeRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 0) {
                        ForEach(row, id: \.self) { kind in shapeCell(kind) }
                    }
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(BotLookCatalog.swatchRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 0) {
                        ForEach(row) { option in swatchCell(option) }
                    }
                    .frame(height: HermesMetrics.swatchRowPitch)
                }
            }
            .padding(.top, 15)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("botLookPicker")
    }

    private func spec(for kind: BlobKind) -> BotAvatarSpec {
        BotAvatarSpec(
            name: seed,
            meta: BotAvatarMeta(shape: BotLookCatalog.shapeString(seed: seed, kind: kind), color: colorHex, custom: true)
        )
    }

    private func shapeCell(_ kind: BlobKind) -> some View {
        let isSelected = kind == shape
        return Button { shape = kind } label: {
            BotAvatarView(spec: spec(for: kind), size: HermesMetrics.pickerShapeFrame, animated: false)
                .frame(width: HermesMetrics.pickerCell, height: HermesMetrics.pickerCell)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color(theme.palette.selectionRing), lineWidth: 2.4)
                            .frame(width: 48, height: 48)
                            .rotationEffect(.degrees(-7))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(BotLookCatalog.displayName(of: kind)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("botShape-\(kind.rawValue)")
    }

    private func swatchCell(_ option: BotLookCatalog.Swatch) -> some View {
        let isSelected = option.hex.caseInsensitiveCompare(colorHex) == .orderedSame
        let color = AvatarColor(css: option.hex)?.swiftUIColor ?? .gray
        return Button { colorHex = option.hex } label: {
            ZStack {
                Circle().fill(color).frame(width: HermesMetrics.swatchDiameter, height: HermesMetrics.swatchDiameter)
                if isSelected {
                    Circle()
                        .strokeBorder(Color(theme.palette.selectionRing), lineWidth: 2.4)
                        .frame(width: HermesMetrics.swatchSelectedDiameter, height: HermesMetrics.swatchSelectedDiameter)
                }
            }
            .frame(width: HermesMetrics.swatchPitch, height: HermesMetrics.swatchRowPitch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(option.name)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("botSwatch-\(option.hex.dropFirst())")
    }
}
