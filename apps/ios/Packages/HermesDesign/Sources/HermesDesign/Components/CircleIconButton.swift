import SwiftUI

public struct CircleIcon: View {
    public let systemName: String
    public let diameter: CGFloat

    @Environment(\.hermesTheme) private var theme

    public init(systemName: String, diameter: CGFloat = HermesMetrics.circleButtonDiameter) {
        self.systemName = systemName
        self.diameter = diameter
    }

    public var body: some View {
        Image(systemName: systemName)
            .font(.system(size: diameter * 0.4, weight: .medium))
            .foregroundStyle(Color(theme.palette.textPrimary))
            .frame(width: diameter, height: diameter)
            .background(Color(theme.palette.circleButtonFill), in: Circle())
            .overlay(Circle().strokeBorder(Color(theme.palette.circleButtonStroke), lineWidth: HermesMetrics.circleButtonStrokeWidth))
            .contentShape(Circle())
    }
}

public struct CircleIconButton: View {
    public let systemName: String
    public let accessibilityLabel: String
    public let accessibilityIdentifier: String
    public let diameter: CGFloat
    public let action: () -> Void

    public init(
        systemName: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        diameter: CGFloat = HermesMetrics.circleButtonDiameter,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier
        self.diameter = diameter
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            CircleIcon(systemName: systemName, diameter: diameter)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
