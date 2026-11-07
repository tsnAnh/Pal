import SwiftUI

public struct CircleIconButton: View {
    public let systemName: String
    public let accessibilityLabel: String
    public let accessibilityIdentifier: String
    public let diameter: CGFloat
    public let action: () -> Void

    @Environment(\.hermesTheme) private var theme

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
            Image(systemName: systemName)
                .font(.system(size: diameter * 0.4, weight: .medium))
                .foregroundStyle(Color(theme.palette.textPrimary))
                .frame(width: diameter, height: diameter)
                .background(Color(theme.palette.circleButtonFill), in: Circle())
                .overlay(Circle().strokeBorder(Color(theme.palette.circleButtonStroke), lineWidth: HermesMetrics.circleButtonStrokeWidth))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
