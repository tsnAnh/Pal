import SwiftUI

public enum ConnectRowMetrics {
    public static let horizontalMargin: CGFloat = 22
    public static let tileSize: CGFloat = 40
    public static let tileRadius: CGFloat = 10
    public static let tileToTextGap: CGFloat = 14
    public static let verticalPadding: CGFloat = 13
    public static let titleSize: CGFloat = 16
    public static let subtitleSize: CGFloat = 12.5
    public static let sectionTitleSize: CGFloat = 16
    public static let captionSize: CGFloat = 12.5
    public static let summaryLineLimit = 2
}

public enum ConnectTileStyle: Sendable {
    case plain
    case filled(RGB)
}

public struct AppTile<Content: View>: View {
    public let style: ConnectTileStyle
    private let content: Content

    public init(style: ConnectTileStyle = .plain, @ViewBuilder content: () -> Content) {
        self.style = style
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: ConnectRowMetrics.tileRadius, style: .continuous)
        content
            .frame(width: ConnectRowMetrics.tileSize, height: ConnectRowMetrics.tileSize)
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(PalTokens.panelBorder, lineWidth: 1))
            .clipShape(shape)
            .accessibilityHidden(true)
    }

    private var fill: Color {
        switch style {
        case .plain: PalTokens.control
        case .filled(let color): Color(color)
        }
    }
}

public struct PluginGlyphTile: View {
    @Environment(\.hermesTheme) private var theme

    public init() {}

    public var body: some View {
        AppTile {
            PalIcon("puzzlepiece.extension")
                .font(.system(size: 20, weight: .regular))
        }
    }
}

public struct ConnectRowAction {
    public let title: String
    public let kind: PillKind
    public let action: () -> Void

    public init(_ title: String, kind: PillKind = .neutral, action: @escaping () -> Void) {
        self.title = title
        self.kind = kind
        self.action = action
    }
}

public enum ConnectStatusTone: Sendable {
    case positive
    case attention
    case neutral
}

public struct ConnectRowStatus: Sendable, Equatable {
    public let title: String
    public let tone: ConnectStatusTone

    public init(_ title: String, tone: ConnectStatusTone) {
        self.title = title
        self.tone = tone
    }
}

public struct ConnectStatusChip: View {
    public let status: ConnectRowStatus

    @Environment(\.hermesTheme) private var theme

    public init(_ status: ConnectRowStatus) {
        self.status = status
    }

    public var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(status.title).lineLimit(1)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(status.tone == .neutral ? PalTokens.textTertiary : tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(status.tone == .neutral ? PalTokens.chipFill : tint.opacity(0.14), in: Capsule())
        .fixedSize()
    }

    private var tint: Color {
        switch status.tone {
        case .positive: .green
        case .attention: Color(theme.palette.accentBlue)
        case .neutral: PalTokens.textTertiary
        }
    }
}

public struct ConnectAppRow<Icon: View>: View {
    public let title: String
    public let summary: String
    public let accessibilityIdentifier: String
    public let isBusy: Bool
    public let status: ConnectRowStatus?
    public let inset: CGFloat
    public let trailing: ConnectRowAction?
    private let icon: Icon

    @Environment(\.hermesTheme) private var theme

    public init(
        title: String,
        summary: String,
        accessibilityIdentifier: String,
        isBusy: Bool = false,
        status: ConnectRowStatus? = nil,
        inset: CGFloat = ConnectRowMetrics.horizontalMargin,
        trailing: ConnectRowAction?,
        @ViewBuilder icon: () -> Icon
    ) {
        self.title = title
        self.summary = summary
        self.accessibilityIdentifier = accessibilityIdentifier
        self.isBusy = isBusy
        self.status = status
        self.inset = inset
        self.trailing = trailing
        self.icon = icon()
    }

    public var body: some View {
        HStack(spacing: ConnectRowMetrics.tileToTextGap) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: ConnectRowMetrics.titleSize))
                        .foregroundStyle(Color(theme.palette.textPrimary))
                        .lineLimit(1)
                    if let status { ConnectStatusChip(status) }
                }
                if !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: ConnectRowMetrics.subtitleSize))
                        .foregroundStyle(Color(theme.palette.textSecondary))
                        .lineLimit(ConnectRowMetrics.summaryLineLimit)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if let trailing {
                Button(action: trailing.action) {
                    ZStack {
                        Text(trailing.title).opacity(isBusy ? 0 : 1)
                        if isBusy { ProgressView().controlSize(.small) }
                    }
                }
                .buttonStyle(.pill(trailing.kind))
                .disabled(isBusy)
                .accessibilityLabel(Text("\(trailing.title) \(title)"))
                .accessibilityIdentifier("\(accessibilityIdentifier)-action")
            }
        }
        .padding(.horizontal, inset)
        .padding(.vertical, ConnectRowMetrics.verticalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

public struct ConnectSectionHeader: View {
    public let title: String
    public let accessibilityIdentifier: String
    public let action: (() -> Void)?

    @Environment(\.hermesTheme) private var theme

    public init(_ title: String, accessibilityIdentifier: String, action: (() -> Void)? = nil) {
        self.title = title
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    public var body: some View {
        Group {
            if let action {
                Button(action: action) { label(showsChevron: true) }.buttonStyle(.plain)
            } else {
                label(showsChevron: false)
            }
        }
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func label(showsChevron: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PalTokens.textSecondary)
            if showsChevron {
                PalIcon("chevron.right", ink: .tertiary)
                    .font(.system(size: 10, weight: .semibold))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ConnectRowMetrics.horizontalMargin)
        .padding(.top, 20)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
    }
}
