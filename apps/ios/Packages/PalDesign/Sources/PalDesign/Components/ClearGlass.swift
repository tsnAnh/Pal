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
