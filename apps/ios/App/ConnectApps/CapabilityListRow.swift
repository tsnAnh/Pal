import PalBotProfile
import PalDesign
import SwiftUI

struct CapabilityListRow: View {
    let row: CapabilityRow
    let isSavingKey: Bool
    let onSetKey: ((String) -> Void)?

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var titleSize = ConnectRowMetrics.titleSize
    @ScaledMetric(relativeTo: .body) private var stateSize = ConnectRowMetrics.captionSize
    @ScaledMetric(relativeTo: .body) private var reasonSize = CapabilityMetrics.reasonSize
    @ScaledMetric(relativeTo: .body) private var onHeight = CapabilityMetrics.onRowMinHeight
    @ScaledMetric(relativeTo: .body) private var limitedHeight = CapabilityMetrics.limitedRowMinHeight

    private var hasAction: Bool { onSetKey != nil && !row.settableKeys.isEmpty }

    private var hasDetail: Bool { row.reason != nil || hasAction }

    private var stacksAction: Bool {
        CapabilityMetrics.metrics(sizeClass: sizeClass) == .phone || typeSize.isAccessibilitySize
    }

    var body: some View {
        HStack(alignment: stacksAction ? .top : .center, spacing: CapabilityMetrics.iconToTextGap) {
            CapabilityStatusIcon(indicator: row.indicator)
            textBlock
            if hasAction, !stacksAction { action }
        }
        .padding(.horizontal, PalMetrics.screenMargin)
        .padding(.vertical, ConnectRowMetrics.verticalPadding)
        .frame(maxWidth: .infinity, minHeight: hasDetail ? limitedHeight : onHeight, alignment: .leading)
        .accessibilityElement(children: hasAction ? .contain : .combine)
        .accessibilityLabel(Text(row.accessibilitySummary))
        .accessibilityIdentifier(row.accessibilityIdentifier)
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            nameLine
            if let reason = row.reason {
                Text(reason)
                    .font(.system(size: reasonSize))
                    .foregroundStyle(PalTokens.textSecondary)
                    .lineLimit(CapabilityMetrics.reasonLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hasAction, stacksAction {
                action.padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var nameLine: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: CapabilityMetrics.nameToStateGap) {
                name.lineLimit(1)
                stateLabel
            }
            VStack(alignment: .leading, spacing: 2) {
                name
                stateLabel
            }
        }
    }

    private var name: some View {
        Text(row.label)
            .font(.system(size: titleSize))
            .foregroundStyle(PalTokens.textPrimary)
    }

    private var stateLabel: some View {
        Text(row.stateWord)
            .font(.system(size: stateSize))
            .foregroundStyle(row.indicator == .limited ? PalTokens.textSecondary : PalTokens.textTertiary)
            .lineLimit(1)
    }

    @ViewBuilder
    private var action: some View {
        if let onSetKey {
            CapabilitySetKeyButton(row: row, isSaving: isSavingKey, onSelect: onSetKey)
        }
    }
}

struct CapabilityStatusIcon: View {
    let indicator: CapabilityIndicator

    @ScaledMetric(relativeTo: .body) private var size = CapabilityMetrics.statusIcon
    @ScaledMetric(relativeTo: .body) private var glyph = CapabilityMetrics.statusGlyph

    var body: some View {
        ZStack {
            switch indicator {
            case .on:
                Circle().fill(PalTokens.chipFill)
                PalIcon(indicator.symbolName, ink: .success).font(.system(size: glyph, weight: .bold))
            case .limited:
                PalIcon(indicator.symbolName, ink: .secondary).font(.system(size: size))
            case .off, .unavailable:
                PalIcon(indicator.symbolName, ink: .tertiary).font(.system(size: size))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct CapabilityGroupCaption: View {
    let group: CapabilityGroup

    @ScaledMetric(relativeTo: .caption) private var size = CapabilityMetrics.groupCaptionSize

    var body: some View {
        Text(group.title)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(group.kind == .off ? PalTokens.textTertiary : PalTokens.textSecondary)
            .padding(.leading, PalMetrics.screenMargin + CapabilityMetrics.groupCaptionLeadingInset)
            .padding(.top, CapabilityMetrics.groupCaptionTopGap)
            .padding(.bottom, CapabilityMetrics.groupCaptionBottomGap)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("capabilityGroupCaption-\(group.identifierSuffix)")
    }
}
