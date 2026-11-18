import PalConnect
import PalDesign
import SwiftUI

struct LegacyReadFailure: View {
    let code: String
    let isBusy: Bool
    let retry: () -> Void

    private var status: SetupStatus {
        var status = SetupStatus(code: code, method: "connectors.legacy")
        status.title = String(localized: "Pal could not read your earlier connections")
        status.reason = code == LegacyConnectionsModel.failedCode
            ? String(localized: "Your computer couldn't answer. Try again.")
            : String(localized: "Pal couldn't read the apps you connected before. Try again, or connect the apps you need below.")
        return status
    }

    var body: some View {
        StatusBlock(status: status, isBusy: isBusy, identifierPrefix: "legacyReadFailure", perform: retry)
            .padding(.vertical, PalMetrics.screenMargin)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("legacyReadFailure")
    }
}

struct LegacyReconnectRowView: View {
    let row: LegacyReconnectRow
    let isBusy: Bool
    let reconnect: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: ConnectRowMetrics.tileToTextGap) {
            PluginGlyphTile()
            VStack(alignment: .leading, spacing: 8) {
                Text(row.item.name)
                    .font(.system(size: ConnectRowMetrics.titleSize))
                    .foregroundStyle(PalTokens.textPrimary)
                    .lineLimit(1)
                Text(row.summary)
                    .font(.system(size: ConnectRowMetrics.subtitleSize))
                    .foregroundStyle(PalTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let title = row.route.actionTitle {
                        SetupButton(title: title, kind: .primary, isBusy: isBusy, identifier: "legacyRow-\(row.id)-reconnect", action: reconnect)
                            .controlSize(.small)
                    }
                    SetupButton(title: String(localized: "Dismiss"), identifier: "legacyRow-\(row.id)-dismiss", action: dismiss)
                        .controlSize(.small)
                        .disabled(isBusy)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, PalMetrics.screenMargin)
        .padding(.vertical, ConnectRowMetrics.verticalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("legacyRow-\(row.id)")
    }
}
