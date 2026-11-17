#if os(macOS)
import PalConnect
import PalDesign
import SwiftUI

struct MacLegacyReconnectRow: View {
    let row: LegacyReconnectRow
    let isBusy: Bool
    let reconnect: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            MacAppTile()
            VStack(alignment: .leading, spacing: 3) {
                Text(row.item.name)
                    .font(.system(size: 12))
                    .foregroundStyle(PalTokens.textPrimary)
                    .lineLimit(1)
                Text(row.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(PalTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                if let title = row.route.actionTitle {
                    MacRowAction(title: title, prominent: true, action: reconnect).view(identifier: "legacyRow-\(row.id)-reconnect")
                }
                MacRowAction(title: String(localized: "Dismiss"), action: dismiss).view(identifier: "legacyRow-\(row.id)-dismiss")
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("legacyRow-\(row.id)")
    }
}

extension MacConnectApps {
    @ViewBuilder
    var legacySection: some View {
        switch model.legacy.display(in: model.catalog) {
        case .hidden:
            EmptyView()
        case .unreadable(let code):
            LegacyReadFailure(code: code, isBusy: model.legacy.isLoading) { Task { await model.retryLegacy() } }
        case .rows(let rows):
            section(title: String(localized: "Reconnect your earlier apps"), identifier: "legacyReconnectTitle", viewAll: nil) {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        MacLegacyReconnectRow(
                            row: row, isBusy: row.route.appID.map(model.busy.contains) ?? false,
                            reconnect: { Task { await model.reconnect(row) } }, dismiss: { model.legacy.dismiss(row) }
                        )
                    }
                }
            }
        }
    }
}
#endif
