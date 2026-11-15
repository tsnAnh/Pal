import SwiftUI

public struct ChatBubble<Content: View>: View {
    public let fill: AnyShapeStyle
    private let content: Content

    public init(fill: Color, @ViewBuilder content: () -> Content) {
        self.fill = AnyShapeStyle(fill)
        self.content = content()
    }

    public init<Style: ShapeStyle>(style: Style, @ViewBuilder content: () -> Content) {
        self.fill = AnyShapeStyle(style)
        self.content = content()
    }

    public var body: some View {
        content
            .padding(.horizontal, ChatMetrics.bubbleHorizontalPadding)
            .padding(.vertical, ChatMetrics.bubbleVerticalPadding)
            .background(fill, in: RoundedRectangle(cornerRadius: ChatMetrics.bubbleRadius, style: .continuous))
    }
}

public struct ChatTimeSeparator: View {
    public let text: String

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .hermesText(.timestamp)
            .foregroundStyle(PalTokens.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, ChatMetrics.separatorTopPadding)
            .padding(.bottom, ChatMetrics.separatorBottomPadding)
            .accessibilityAddTraits(.isHeader)
    }
}

public struct UnreadDivider: View {
    public let label: String
    public let ink: Color

    @Environment(\.hermesTheme) private var theme

    public init(label: String, ink: Color) {
        self.label = label
        self.ink = ink
    }

    public var body: some View {
        HStack(spacing: ChatMetrics.unreadLabelGap) {
            line
            Text(label)
                .hermesText(.unreadLabel)
                .foregroundStyle(ink)
            line
        }
        .padding(.top, ChatMetrics.unreadTopPadding)
        .padding(.bottom, ChatMetrics.unreadBottomPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
    }

    private var line: some View {
        Rectangle()
            .fill(ink.opacity(0.28))
            .frame(height: ChatMetrics.unreadLineThickness)
    }
}

public struct ChatStatusLine: View {
    public let text: String
    public let systemImage: String

    @Environment(\.hermesTheme) private var theme

    public init(text: String, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: ChatMetrics.statusTextGap) {
            Image(systemName: systemImage)
                .font(.system(size: ChatMetrics.statusIconSize, weight: .medium))
                .foregroundStyle(Color(theme.palette.textSecondary))
                .accessibilityHidden(true)
            Text(text)
                .hermesText(.chatStatus)
                .foregroundStyle(Color(theme.palette.textSecondary))
        }
        .padding(.leading, ChatMetrics.statusLeadingInset - ChatMetrics.edgeMargin)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

public struct GlassCircleButton: View {
    public let systemName: String
    public let accessibilityLabel: String
    public let accessibilityIdentifier: String
    public let action: () -> Void

    public init(systemName: String, accessibilityLabel: String, accessibilityIdentifier: String, action: @escaping () -> Void) {
        self.systemName = systemName
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            GlassCircleLabel(systemName: systemName)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

public struct GlassCircleLabel: View {
    public let systemName: String
    public let diameter: CGFloat

    @Environment(\.hermesTheme) private var theme

    public init(systemName: String, diameter: CGFloat = ChatMetrics.headerButtonDiameter) {
        self.systemName = systemName
        self.diameter = diameter
    }

    public var body: some View {
        Image(systemName: systemName)
            .font(.system(size: diameter * 0.42, weight: .medium))
            .foregroundStyle(Color(theme.palette.textPrimary))
            .frame(width: diameter, height: diameter)
            .palGlass(Circle())
            .contentShape(Circle())
    }
}

public struct ScrollToBottomButton: View {
    public let newCount: Int
    public let action: () -> Void

    @Environment(\.hermesTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(newCount: Int = 0, action: @escaping () -> Void) {
        self.newCount = newCount
        self.action = action
    }

    private var diameter: CGFloat { ChatMetrics.scrollButtonDiameter }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                if newCount > 0 {
                    Text("\(newCount) new")
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(newCount)))
                        .fixedSize()
                        .transition(.opacity)
                }
            }
            .foregroundStyle(Color(theme.palette.textPrimary))
            .padding(.horizontal, newCount > 0 ? 14 : 0)
            .frame(minWidth: diameter, minHeight: diameter, maxHeight: diameter)
            .palGlass(Capsule())
            .overlay(Capsule().strokeBorder(PalTokens.textPrimary.opacity(0.08), lineWidth: 1))
            .frame(minWidth: ChatMetrics.minimumHitTarget, minHeight: ChatMetrics.minimumHitTarget)
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0), value: newCount)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(newCount > 0 ? Text("\(newCount) new messages. Scroll to latest") : Text("Scroll to latest"))
        .accessibilityIdentifier("scrollToBottomButton")
    }
}
