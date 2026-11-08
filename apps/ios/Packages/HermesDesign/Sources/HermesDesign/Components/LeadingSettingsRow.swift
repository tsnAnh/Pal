import SwiftUI

public struct LeadingSettingsRow<Leading: View>: View {
    public let title: String
    public let subtitle: String?
    public let value: String?
    public let trailing: SettingsRow.Trailing
    public let role: SettingsRow.Role
    public let leadingSpacing: CGFloat
    public let accessibilityIdentifier: String
    public let action: (() -> Void)?
    private let leading: Leading

    @Environment(\.hermesTheme) private var theme

    public init(
        title: String,
        subtitle: String? = nil,
        value: String? = nil,
        trailing: SettingsRow.Trailing = .none,
        role: SettingsRow.Role = .standard,
        leadingSpacing: CGFloat = 10,
        accessibilityIdentifier: String,
        action: (() -> Void)? = nil,
        @ViewBuilder leading: () -> Leading
    ) {
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.trailing = trailing
        self.role = role
        self.leadingSpacing = leadingSpacing
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
        self.leading = leading()
    }

    public var body: some View {
        if let action {
            Button(action: action) { rowContent }
                .buttonStyle(.plain)
                .accessibilityIdentifier(accessibilityIdentifier)
        } else {
            rowContent
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
    }

    private var titleColor: Color {
        Color(role == .destructive ? theme.palette.destructive : theme.palette.textPrimary)
    }

    private var rowContent: some View {
        HStack(spacing: leadingSpacing) {
            leading
            VStack(alignment: .leading, spacing: HermesMetrics.rowTextSpacing) {
                Text(title)
                    .hermesText(.rowTitle)
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .hermesText(.rowSubtitle)
                        .foregroundStyle(Color(theme.palette.textSecondary))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let value {
                Text(value)
                    .hermesText(.rowValue)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .lineLimit(1)
            }
            accessory
        }
        .padding(.horizontal, HermesMetrics.rowInset)
        .padding(.vertical, subtitle == nil ? 0 : HermesMetrics.rowVerticalPadding)
        .frame(minHeight: HermesMetrics.rowMinimumHeight)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var accessory: some View {
        switch trailing {
        case .chevron:
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color(theme.palette.chevron))
                .accessibilityHidden(true)
        case .external:
            Image(systemName: "arrow.up.right")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color(theme.palette.chevron))
                .accessibilityHidden(true)
        case .none, .toggle:
            EmptyView()
        }
    }
}

public struct StatusDot: View {
    public let isOn: Bool

    @Environment(\.hermesTheme) private var theme

    public init(isOn: Bool) {
        self.isOn = isOn
    }

    public var body: some View {
        Circle()
            .fill(isOn ? Color(red: 0.25, green: 0.69, blue: 0.35) : Color(theme.palette.textTertiary))
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }
}

public struct InitialAvatar: View {
    public let initial: String
    public let diameter: CGFloat

    @Environment(\.hermesTheme) private var theme

    public init(initial: String, diameter: CGFloat = 40) {
        self.initial = initial
        self.diameter = diameter
    }

    public var body: some View {
        Text(initial)
            .font(.system(size: diameter * 0.42, weight: .medium))
            .foregroundStyle(Color(theme.palette.textPrimary))
            .frame(width: diameter, height: diameter)
            .background(Color(theme.palette.circleButtonFill), in: Circle())
            .overlay(Circle().strokeBorder(Color(theme.palette.circleButtonStroke), lineWidth: HermesMetrics.circleButtonStrokeWidth))
            .accessibilityHidden(true)
    }
}
