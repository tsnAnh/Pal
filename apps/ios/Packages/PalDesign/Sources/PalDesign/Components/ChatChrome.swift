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

    @Environment(\.hermesTheme) private var theme

    public init(label: String) {
        self.label = label
    }

    public var body: some View {
        HStack(spacing: ChatMetrics.unreadLabelGap) {
            line
            Text(label)
                .hermesText(.unreadLabel)
                .foregroundStyle(Color(theme.palette.accentBlue))
            line
        }
        .padding(.top, ChatMetrics.unreadTopPadding)
        .padding(.bottom, ChatMetrics.unreadBottomPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
    }

    private var line: some View {
        Rectangle()
            .fill(Color(theme.palette.unreadLine))
            .frame(height: ChatMetrics.unreadLineThickness)
    }
}

public struct ChatStatusLine: View {
    public let text: String
    public let dotColor: Color

    @Environment(\.hermesTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(text: String, dotColor: Color) {
        self.text = text
        self.dotColor = dotColor
    }

    public var body: some View {
        HStack(spacing: ChatMetrics.statusTextGap) {
            dots
            Text(text)
                .hermesText(.chatStatus)
                .foregroundStyle(Color(theme.palette.textSecondary))
        }
        .padding(.leading, ChatMetrics.statusLeadingInset - ChatMetrics.edgeMargin)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var dots: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0.5 : context.date.timeIntervalSinceReferenceDate
            HStack(spacing: ChatMetrics.statusDotSpacing) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = (sin(time * 5 - Double(index) * 0.9) + 1) / 2
                    Circle()
                        .fill(dotColor.opacity(0.45 + 0.55 * phase))
                        .frame(width: ChatMetrics.statusDotDiameter, height: ChatMetrics.statusDotDiameter)
                        .scaleEffect(0.8 + 0.2 * phase)
                }
            }
        }
        .accessibilityHidden(true)
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
    public let action: () -> Void

    @Environment(\.hermesTheme) private var theme

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(theme.palette.textPrimary))
                .frame(width: ChatMetrics.scrollButtonDiameter, height: ChatMetrics.scrollButtonDiameter)
                .palGlass(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Scroll to latest"))
        .accessibilityIdentifier("scrollToBottomButton")
    }
}
