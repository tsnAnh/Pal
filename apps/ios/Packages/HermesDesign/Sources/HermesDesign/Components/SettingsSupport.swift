import SwiftUI

public struct SectionHeader<Trailing: View>: View {
    public let title: String
    public let subtitle: String?
    public let accessibilityIdentifier: String
    private let trailing: Trailing

    @Environment(\.hermesTheme) private var theme

    public init(
        _ title: String,
        subtitle: String? = nil,
        accessibilityIdentifier: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessibilityIdentifier = accessibilityIdentifier
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color(theme.palette.textSecondary).opacity(0.8))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color(theme.palette.sectionCaption))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, HermesMetrics.screenMargin + HermesMetrics.rowInset - 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

extension SectionHeader where Trailing == EmptyView {
    public init(_ title: String, subtitle: String? = nil, accessibilityIdentifier: String) {
        self.init(title, subtitle: subtitle, accessibilityIdentifier: accessibilityIdentifier, trailing: { EmptyView() })
    }
}

public struct PlaceholderRow: View {
    public let text: String
    public let accessibilityIdentifier: String

    @Environment(\.hermesTheme) private var theme

    public init(_ text: String, accessibilityIdentifier: String) {
        self.text = text
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    public var body: some View {
        Text(text)
            .hermesText(.rowTitle)
            .foregroundStyle(Color(theme.palette.sectionCaption))
            .padding(.horizontal, HermesMetrics.rowInset)
            .frame(maxWidth: .infinity, minHeight: HermesMetrics.rowMinimumHeight, alignment: .leading)
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}

public struct CardFootnote: View {
    public let text: String
    public let accessibilityIdentifier: String

    @Environment(\.hermesTheme) private var theme

    public init(_ text: String, accessibilityIdentifier: String) {
        self.text = text
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    public var body: some View {
        Text(text)
            .hermesText(.rowSubtitle)
            .foregroundStyle(Color(theme.palette.sectionCaption))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, HermesMetrics.screenMargin + HermesMetrics.rowInset - 3)
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}

public struct BrandMarkFooter: View {
    public let name: String
    public let version: String

    @Environment(\.hermesTheme) private var theme

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }

    public var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(.white)
                HStack(spacing: 14) {
                    Capsule().frame(width: 6, height: 16).rotationEffect(.degrees(-9))
                    Capsule().frame(width: 6, height: 16).rotationEffect(.degrees(9))
                }
                .foregroundStyle(Color.black.opacity(0.88))
                .offset(y: -1)
            }
            .frame(width: 51, height: 51)
            .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(name)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color(theme.palette.textPrimary))
                Text(version)
                    .hermesText(.rowValue)
                    .foregroundStyle(Color(theme.palette.sectionCaption))
                    .accessibilityIdentifier("settingsVersion")
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settingsFooter")
    }
}
