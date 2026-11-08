import SwiftUI

public struct AvatarBadge<Content: View>: View {
    public let diameter: CGFloat
    public let showsPrimaryBadge: Bool
    public let accessibilityIdentifier: String
    private let content: Content

    @Environment(\.hermesTheme) private var theme

    public init(
        diameter: CGFloat,
        showsPrimaryBadge: Bool,
        accessibilityIdentifier: String,
        @ViewBuilder content: () -> Content
    ) {
        self.diameter = diameter
        self.showsPrimaryBadge = showsPrimaryBadge
        self.accessibilityIdentifier = accessibilityIdentifier
        self.content = content()
    }

    public var body: some View {
        content
            .frame(width: diameter, height: diameter)
            .overlay {
                if showsPrimaryBadge { badge }
            }
            .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var badge: some View {
        let badgeDiameter = diameter * HermesMetrics.primaryBadgeDiameterRatio
        let ring = diameter * HermesMetrics.primaryBadgeRingRatio
        let offset = diameter * HermesMetrics.primaryBadgeCenterOffsetRatio
        return Image(systemName: "star.fill")
            .font(.system(size: badgeDiameter * 0.5, weight: .bold))
            .foregroundStyle(Color(theme.palette.primaryBadgeGlyph))
            .frame(width: badgeDiameter, height: badgeDiameter)
            .background(Color(theme.palette.primaryBadge), in: Circle())
            .overlay(Circle().strokeBorder(Color(theme.palette.canvas), lineWidth: ring).padding(-ring))
            .offset(x: offset, y: offset)
            .accessibilityHidden(true)
    }
}
