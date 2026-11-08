import SwiftUI

public enum ConnectRowMetrics {
    public static let horizontalMargin: CGFloat = 22
    public static let tileSize: CGFloat = 40
    public static let tileRadius: CGFloat = 10
    public static let tileToTextGap: CGFloat = 14
    public static let verticalPadding: CGFloat = 13
    public static let titleSize: CGFloat = 17
    public static let subtitleSize: CGFloat = 14
    public static let sectionTitleSize: CGFloat = 18
    public static let captionSize: CGFloat = 14.5
    public static let summaryLineLimit = 2
}

public enum ConnectTileStyle: Sendable {
    case plain
    case filled(RGB)
}

public struct AppTile<Content: View>: View {
    public let style: ConnectTileStyle
    private let content: Content

    @Environment(\.hermesTheme) private var theme

    public init(style: ConnectTileStyle = .plain, @ViewBuilder content: () -> Content) {
        self.style = style
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: ConnectRowMetrics.tileRadius, style: .continuous)
        content
            .frame(width: ConnectRowMetrics.tileSize, height: ConnectRowMetrics.tileSize)
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(Color(theme.palette.tileStroke), lineWidth: 1))
            .clipShape(shape)
            .accessibilityHidden(true)
    }

    private var fill: Color {
        switch style {
        case .plain: Color(theme.palette.groupedCard)
        case .filled(let color): Color(color)
        }
    }
}

public struct PluginGlyphTile: View {
    @Environment(\.hermesTheme) private var theme

    public init() {}

    public var body: some View {
        AppTile {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Color(theme.palette.textPrimary))
        }
    }
}

public struct RemoteLogoTile: View {
    public let url: URL?

    public init(url: URL?) {
        self.url = url
    }

    public var body: some View {
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    AppTile(style: .filled(RGB(hex: 0xffffff))) {
                        image.resizable().scaledToFit().padding(7)
                    }
                default:
                    PluginGlyphTile()
                }
            }
        } else {
            PluginGlyphTile()
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

public struct ConnectAppRow<Icon: View>: View {
    public let title: String
    public let summary: String
    public let accessibilityIdentifier: String
    public let isBusy: Bool
    public let trailing: ConnectRowAction?
    private let icon: Icon

    @Environment(\.hermesTheme) private var theme

    public init(
        title: String,
        summary: String,
        accessibilityIdentifier: String,
        isBusy: Bool = false,
        trailing: ConnectRowAction?,
        @ViewBuilder icon: () -> Icon
    ) {
        self.title = title
        self.summary = summary
        self.accessibilityIdentifier = accessibilityIdentifier
        self.isBusy = isBusy
        self.trailing = trailing
        self.icon = icon()
    }

    public var body: some View {
        HStack(spacing: ConnectRowMetrics.tileToTextGap) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: ConnectRowMetrics.titleSize))
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .lineLimit(1)
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
        .padding(.horizontal, ConnectRowMetrics.horizontalMargin)
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
                .font(.system(size: ConnectRowMetrics.sectionTitleSize))
                .foregroundStyle(Color(theme.palette.textPrimary))
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color(theme.palette.textPrimary))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ConnectRowMetrics.horizontalMargin)
        .padding(.top, 22)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
    }
}

public struct ConnectedCountButton: View {
    public let title: String
    public let accessibilityIdentifier: String
    public let action: () -> Void

    @Environment(\.hermesTheme) private var theme

    public init(_ title: String, accessibilityIdentifier: String, action: @escaping () -> Void) {
        self.title = title
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17))
                .foregroundStyle(Color(theme.palette.textPrimary))
                .padding(.horizontal, 20)
                .frame(height: HermesMetrics.circleButtonDiameter)
                .background(Color(theme.palette.circleButtonFill), in: Capsule())
                .overlay(Capsule().strokeBorder(Color(theme.palette.circleButtonStroke), lineWidth: HermesMetrics.circleButtonStrokeWidth))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
