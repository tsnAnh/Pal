import SwiftUI

public extension View {
    func palClearGlass<S: Shape>(_ shape: S, interactive: Bool = true) -> some View {
        glassEffect(interactive ? Glass.clear.interactive() : Glass.clear, in: shape)
    }
}

public struct PalClearGlassIconButton: View {
    public let systemName: String
    public let label: LocalizedStringKey
    public let identifier: String
    public let diameter: CGFloat
    public let action: () -> Void

    public init(
        systemName: String,
        label: LocalizedStringKey,
        identifier: String,
        diameter: CGFloat = 34,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.label = label
        self.identifier = identifier
        self.diameter = diameter
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            PalIcon(systemName)
                .font(.system(size: diameter * 0.42, weight: .medium))
                .frame(width: diameter, height: diameter)
                .palClearGlass(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(identifier)
    }
}

public struct PalClearCapsuleStyle: ButtonStyle {
    public var height: CGFloat
    public var horizontalPadding: CGFloat
    public var weight: Font.Weight
    public var selected: Bool
    public var fillsWidth: Bool

    @Environment(\.isEnabled) private var isEnabled

    public init(
        height: CGFloat = 32, horizontalPadding: CGFloat = 16, weight: Font.Weight = .semibold, selected: Bool = false, fillsWidth: Bool = false
    ) {
        self.height = height
        self.horizontalPadding = horizontalPadding
        self.weight = weight
        self.selected = selected
        self.fillsWidth = fillsWidth
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: weight))
            .foregroundStyle(PalTokens.textPrimary)
            .padding(.horizontal, horizontalPadding)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(height: height)
            .background(selected ? PalTokens.textPrimary.opacity(0.14) : Color.clear, in: Capsule())
            .palClearGlass(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.6)
            .contentShape(Capsule())
    }
}

public extension ButtonStyle where Self == PalClearCapsuleStyle {
    static var palClearCapsule: PalClearCapsuleStyle { PalClearCapsuleStyle() }

    static func palClearChip(selected: Bool) -> PalClearCapsuleStyle {
        PalClearCapsuleStyle(height: 30, horizontalPadding: 14, weight: selected ? .semibold : .regular, selected: selected)
    }

    static var palClearWide: PalClearCapsuleStyle {
        PalClearCapsuleStyle(height: 38, fillsWidth: true)
    }
}

public struct ClearGlassSearchField: View {
    @Binding public var text: String
    public let prompt: String
    public let accessibilityLabel: String
    public let accessibilityIdentifier: String
    public let height: CGFloat
    public let fontSize: CGFloat

    public init(
        text: Binding<String>, prompt: String, accessibilityLabel: String, accessibilityIdentifier: String,
        height: CGFloat = 38, fontSize: CGFloat = 14
    ) {
        _text = text
        self.prompt = prompt
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier
        self.height = height
        self.fontSize = fontSize
    }

    public var body: some View {
        HStack(spacing: 8) {
            PalIcon("magnifyingglass", ink: .secondary)
                .font(.system(size: fontSize))
                .accessibilityHidden(true)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(PalTokens.textTertiary))
                .textFieldStyle(.plain)
                .font(.system(size: fontSize))
                .foregroundStyle(PalTokens.textPrimary)
                .autocorrectionDisabled()
                .accessibilityLabel(Text(accessibilityLabel))
                .accessibilityIdentifier(accessibilityIdentifier)
        }
        .padding(.horizontal, 14)
        .frame(height: height)
        .palClearGlass(Capsule(), interactive: false)
    }
}
