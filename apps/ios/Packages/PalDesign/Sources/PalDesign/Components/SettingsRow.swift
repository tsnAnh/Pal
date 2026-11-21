import SwiftUI

public struct RowIcon {
    let content: AnyView

    public static func symbol(_ name: String) -> RowIcon {
        RowIcon(content: AnyView(PalIcon(name, ink: .secondary).font(.system(size: 17, weight: .light))))
    }

    public static func custom<Content: View>(_ view: Content) -> RowIcon {
        RowIcon(content: AnyView(view))
    }
}

extension PalMetrics {
    public static let rowIconLeadingInset: CGFloat = 22
    public static let rowIconWidth: CGFloat = 19
    public static let rowIconSpacing: CGFloat = 12.5
}

public struct SettingsRow: View {
    public enum Trailing {
        case none
        case chevron
        case external
        case toggle(Binding<Bool>)
    }

    public enum Role: Sendable {
        case standard
        case destructive
    }

    public let title: String
    public let subtitle: String?
    public let value: String?
    public let trailing: Trailing
    public let role: Role
    public let icon: RowIcon?
    public let minimumHeight: CGFloat
    public let accessibilityIdentifier: String
    public let action: (() -> Void)?

    @Environment(\.hermesTheme) private var theme

    public init(
        title: String,
        subtitle: String? = nil,
        value: String? = nil,
        trailing: Trailing = .none,
        role: Role = .standard,
        icon: RowIcon? = nil,
        minimumHeight: CGFloat = PalMetrics.rowMinimumHeight,
        accessibilityIdentifier: String,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.trailing = trailing
        self.role = role
        self.icon = icon
        self.minimumHeight = minimumHeight
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    public static func navigate(
        _ title: String,
        subtitle: String? = nil,
        value: String? = nil,
        icon: RowIcon? = nil,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> SettingsRow {
        SettingsRow(title: title, subtitle: subtitle, value: value, trailing: .chevron, icon: icon, accessibilityIdentifier: accessibilityIdentifier, action: action)
    }

    public static func value(
        _ title: String,
        value: String,
        subtitle: String? = nil,
        icon: RowIcon? = nil,
        accessibilityIdentifier: String
    ) -> SettingsRow {
        SettingsRow(title: title, subtitle: subtitle, value: value, icon: icon, accessibilityIdentifier: accessibilityIdentifier)
    }

    public static func external(
        _ title: String,
        subtitle: String? = nil,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> SettingsRow {
        SettingsRow(title: title, subtitle: subtitle, trailing: .external, accessibilityIdentifier: accessibilityIdentifier, action: action)
    }

    public static func toggle(
        _ title: String,
        subtitle: String? = nil,
        isOn: Binding<Bool>,
        minimumHeight: CGFloat = PalMetrics.rowMinimumHeight,
        accessibilityIdentifier: String
    ) -> SettingsRow {
        SettingsRow(title: title, subtitle: subtitle, trailing: .toggle(isOn), minimumHeight: minimumHeight, accessibilityIdentifier: accessibilityIdentifier)
    }

    public static func destructive(
        _ title: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> SettingsRow {
        SettingsRow(title: title, role: .destructive, accessibilityIdentifier: accessibilityIdentifier, action: action)
    }

    public var body: some View {
        switch trailing {
        case .toggle:
            rowContent
        default:
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
    }

    private var isToggle: Bool {
        if case .toggle = trailing { return true }
        return false
    }

    private var titleColor: Color {
        Color(role == .destructive ? theme.palette.destructive : theme.palette.textPrimary)
    }

    private var rowContent: some View {
        HStack(spacing: icon == nil ? 12 : PalMetrics.rowIconSpacing) {
            if let icon {
                icon.content
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .frame(width: PalMetrics.rowIconWidth)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: PalMetrics.rowTextSpacing) {
                Text(title)
                    .hermesText(.rowTitle)
                    .foregroundStyle(titleColor)
                if let subtitle {
                    Text(subtitle)
                        .hermesText(.rowSubtitle)
                        .foregroundStyle(Color(theme.palette.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(isToggle)
            if let value {
                Text(value)
                    .hermesText(.rowValue)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .lineLimit(1)
            }
            trailingAccessory
        }
        .padding(.leading, icon == nil ? PalMetrics.rowInset : PalMetrics.rowIconLeadingInset)
        .padding(.trailing, PalMetrics.rowInset)
        .padding(.vertical, subtitle == nil ? 0 : PalMetrics.rowVerticalPadding)
        .frame(minHeight: minimumHeight)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        switch trailing {
        case .none:
            EmptyView()
        case .chevron:
            PalIcon("chevron.right", ink: .tertiary)
                .font(.system(size: 14, weight: .regular))
                .accessibilityHidden(true)
        case .external:
            PalIcon("arrow.up.right", ink: .tertiary)
                .font(.system(size: 14, weight: .regular))
                .accessibilityHidden(true)
        case .toggle(let isOn):
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .palSwitch()
                .accessibilityLabel(Text(title))
                .accessibilityIdentifier(accessibilityIdentifier)
        }
    }
}
