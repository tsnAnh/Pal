import SwiftUI

public struct AppearanceTile: View {
    public let title: String
    public let isSelected: Bool
    public let accessibilityIdentifier: String
    public let action: () -> Void
    private let icon: AppearanceTileIcon

    @Environment(\.hermesTheme) private var theme

    public init(
        title: String,
        icon: AppearanceTileIcon,
        isSelected: Bool,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.isSelected = isSelected
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous)
        Button(action: action) {
            VStack(spacing: 10) {
                icon
                    .foregroundStyle(Color(isSelected ? theme.palette.textPrimary : theme.palette.textSecondary))
                    .frame(maxWidth: .infinity)
                    .frame(height: PalMetrics.appearanceTileHeight)
                    .background(isSelected ? Color(theme.palette.groupedCard) : .clear, in: shape)
                    .overlay(shape.strokeBorder(Color(theme.palette.tileStroke), lineWidth: isSelected ? 0 : PalMetrics.separatorThickness))
                Text(title)
                    .hermesText(.rowTitle)
                    .foregroundStyle(Color(isSelected ? theme.palette.textPrimary : theme.palette.textSecondary))
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

extension PalMetrics {
    public static let appearanceTileHeight: CGFloat = 80
    public static let appearanceTileSpacing: CGFloat = 8
    public static let appearanceRowSpacing: CGFloat = 30
}

public enum AppearanceTileIcon: View {
    case followSystem
    case light
    case dark
    case black
    case botColor

    public var body: some View {
        switch self {
        case .followSystem:
            Image(systemName: "circle.lefthalf.filled").font(.system(size: 26))
        case .light:
            Image(systemName: "sun.max.fill").font(.system(size: 26))
        case .dark:
            Image(systemName: "moon.fill").font(.system(size: 24))
        case .black:
            Circle().frame(width: 26, height: 26)
        case .botColor:
            Circle()
                .fill(AngularGradient(
                    colors: [.red, .orange, .yellow, .green, .teal, .blue, .purple, .pink, .red],
                    center: .center
                ))
                .frame(width: 26, height: 26)
        }
    }
}
