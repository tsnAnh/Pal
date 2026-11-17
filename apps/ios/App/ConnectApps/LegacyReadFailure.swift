import PalDesign
import SwiftUI

extension ChatStatusCopy {
    init(symbol: String, title: String, reason: String, code: String) {
        self.symbol = symbol
        self.title = title
        self.reason = reason
        self.code = code
    }
}

struct LegacyReadFailure: View {
    let code: String
    let isBusy: Bool
    let retry: () -> Void

    private var copy: ChatStatusCopy {
        let reason = code == LegacyConnectionsModel.failedCode
            ? String(localized: "Your computer couldn't answer. Try again.")
            : String(localized: "Pal couldn't read the apps you connected before. Try again, or connect the apps you need below.")
        return ChatStatusCopy(
            symbol: "exclamationmark.triangle", title: String(localized: "Pal could not read your earlier connections"), reason: reason, code: code
        )
    }

    var body: some View {
        ChatInstallStatus(copy: copy, primaryTitle: String(localized: "Try again"), isBusy: isBusy, perform: retry) { EmptyView() }
            .padding(.vertical, 12)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("legacyReadFailure")
    }
}

struct LegacyReconnectRowView: View {
    let row: LegacyReconnectRow
    let isBusy: Bool
    let inset: CGFloat
    let reconnect: () -> Void
    let dismiss: () -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: ConnectRowMetrics.tileToTextGap) {
            PluginGlyphTile()
            VStack(alignment: .leading, spacing: 8) {
                Text(row.item.name)
                    .font(.system(size: ConnectRowMetrics.titleSize))
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .lineLimit(1)
                Text(row.summary)
                    .font(.system(size: ConnectRowMetrics.subtitleSize))
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let title = row.route.actionTitle {
                        Button(action: reconnect) {
                            ZStack {
                                Text(title).opacity(isBusy ? 0 : 1)
                                if isBusy { ProgressView().controlSize(.small) }
                            }
                        }
                        .buttonStyle(.pill(.accent))
                        .disabled(isBusy)
                        .accessibilityLabel(Text("\(title) \(row.item.name)"))
                        .accessibilityIdentifier("legacyRow-\(row.id)-reconnect")
                    }
                    Button(String(localized: "Dismiss"), action: dismiss)
                        .buttonStyle(.pill())
                        .disabled(isBusy)
                        .accessibilityLabel(Text("Dismiss \(row.item.name)"))
                        .accessibilityIdentifier("legacyRow-\(row.id)-dismiss")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, inset)
        .padding(.vertical, ConnectRowMetrics.verticalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("legacyRow-\(row.id)")
    }
}

extension ConnectAppsSheet {
    @ViewBuilder
    var legacySection: some View {
        switch model.legacy.display(in: model.catalog) {
        case .hidden:
            EmptyView()
        case .unreadable(let code):
            LegacyReadFailure(code: code, isBusy: model.legacy.isLoading) { Task { await model.retryLegacy() } }
        case .rows(let rows):
            ConnectSectionHeader("Reconnect your earlier apps", accessibilityIdentifier: "legacyReconnectTitle")
            card {
                ForEach(rows) { row in
                    LegacyReconnectRowView(
                        row: row, isBusy: row.route.appID.map(model.busy.contains) ?? false, inset: Self.cardInset,
                        reconnect: { Task { await model.reconnect(row) } }, dismiss: { model.legacy.dismiss(row) }
                    )
                }
            }
        }
    }
}
