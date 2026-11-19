import PalBotProfile
import PalDesign
import SwiftUI

struct CapabilityListRow: View {
    let row: CapabilityRow
    let onSetKey: ((String) -> Void)?

    @Environment(\.hermesTheme) var theme

    var body: some View {
        HStack(alignment: .top, spacing: ConnectRowMetrics.tileToTextGap) {
            PalIcon(row.indicator.symbolName, ink: indicatorInk)
                .font(.system(size: 20))
                .frame(width: ConnectRowMetrics.tileSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(row.label)
                        .font(.system(size: ConnectRowMetrics.titleSize))
                        .foregroundStyle(PalTokens.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(row.stateWord)
                        .font(.system(size: ConnectRowMetrics.subtitleSize))
                        .foregroundStyle(PalTokens.textSecondary)
                }
                if let reason = row.reason {
                    Text(reason)
                        .font(.system(size: ConnectRowMetrics.subtitleSize))
                        .foregroundStyle(PalTokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let key = row.shownKeyName {
                    Text(key)
                        .font(.system(size: ConnectRowMetrics.subtitleSize, design: .monospaced))
                        .foregroundStyle(Color(theme.palette.chipText))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(theme.palette.chipFill), in: Capsule())
                        .padding(.top, 2)
                }
                if let onSetKey {
                    CapabilitySetKeyButton(row: row, onSelect: onSetKey)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, PalMetrics.screenMargin)
        .padding(.vertical, ConnectRowMetrics.verticalPadding)
        .accessibilityElement(children: onSetKey == nil ? .combine : .contain)
        .accessibilityLabel(Text(row.accessibilitySummary))
        .accessibilityIdentifier(row.accessibilityIdentifier)
    }

    private var indicatorInk: PalIconInk {
        switch row.indicator {
        case .on: .primary
        case .limited: .secondary
        case .off, .unavailable: .tertiary
        }
    }
}
