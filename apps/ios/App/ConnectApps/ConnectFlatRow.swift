import PalConnect
import PalDesign
import SwiftUI

struct ConnectFlatRow<Icon: View, Trailing: View>: View {
    let title: String
    let subtitle: String
    let problem: Bool
    let identifier: String
    private let icon: Icon
    private let trailing: Trailing

    @Environment(\.hermesTheme) private var theme

    init(
        title: String, subtitle: String, problem: Bool = false, identifier: String,
        @ViewBuilder icon: () -> Icon, @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.problem = problem
        self.identifier = identifier
        self.icon = icon()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: ConnectRowMetrics.tileToTextGap) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: ConnectRowMetrics.titleSize))
                    .foregroundStyle(PalTokens.textPrimary)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: ConnectRowMetrics.subtitleSize))
                        .foregroundStyle(problem ? Color(theme.palette.destructive) : PalTokens.textSecondary)
                        .lineLimit(ConnectRowMetrics.summaryLineLimit)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            trailing
        }
        .padding(.horizontal, PalMetrics.screenMargin)
        .padding(.vertical, ConnectRowMetrics.verticalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

struct ConnectRowDivider: View {
    static let inset = PalMetrics.screenMargin + ConnectRowMetrics.tileSize + ConnectRowMetrics.tileToTextGap

    var body: some View {
        PalHairline().padding(.leading, Self.inset)
    }
}

struct ConnectFlatRows<Data: RandomAccessCollection, Row: View>: View where Data.Element: Identifiable {
    let data: Data
    let row: (Data.Element) -> Row

    init(_ data: Data, @ViewBuilder row: @escaping (Data.Element) -> Row) {
        self.data = data
        self.row = row
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(data.enumerated()), id: \.element.id) { index, element in
                if index > 0 { ConnectRowDivider() }
                row(element)
            }
        }
    }
}

struct ConnectFlatSectionHeader: View {
    let title: String
    let identifier: String
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { label(showsChevron: true) }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(identifier)
        } else {
            label(showsChevron: false)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(identifier)
        }
    }

    private func label(showsChevron: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PalTokens.textPrimary)
            Spacer(minLength: 0)
            if showsChevron {
                PalIcon("chevron.right", ink: .tertiary)
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, PalMetrics.screenMargin)
        .padding(.top, 22)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
    }
}

struct ConnectInstalledIcon: View {
    let item: ConnectInstalledItem

    var body: some View {
        switch item.source {
        case .app(let app): ConnectorLogoTile(app: app)
        case .device(let id): DeviceTile(connector: id)
        }
    }
}

extension ConnectMacSection {
    var identifier: String {
        switch kind {
        case .needsAttention: "connectAppsSection-attention"
        case .thisDevice: "connectAppsSection-device-this-device"
        case .featured: "connectAppsSection-featured"
        case .category(let name): "connectAppsSection-\(name)"
        case .results: "connectAppsSection-results"
        }
    }
}
