import PalConnect
import PalDesign
import SwiftUI

private struct StepChoiceCard<Content: View>: View {
    let identifier: String
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous)
        VStack(spacing: 0) { content }
            .background(PalTokens.elevated, in: shape)
            .overlay { shape.strokeBorder(PalTokens.panelBorder, lineWidth: PalMetrics.separatorThickness) }
            .clipShape(shape)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
    }
}

struct StepConfirmList: View {
    let model: StepFlowModel
    let items: [SetupConfirmItem]

    var body: some View {
        StepChoiceCard(identifier: "stepFlowConfirm") {
            ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                if offset > 0 { PalHairline() }
                row(item)
            }
        }
    }

    private func row(_ item: SetupConfirmItem) -> some View {
        let ticked = model.engine.isConfirmed(item.id)
        return Button { model.setConfirmed(item.id, !ticked) } label: {
            HStack(spacing: 12) {
                PalIcon(ticked ? "checkmark.square.fill" : "square", ink: ticked ? .custom(PalTokens.toggleOn) : .tertiary)
                    .font(.system(size: 20))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: PalMetrics.rowTextSpacing) {
                    Text(item.title)
                        .hermesText(.rowTitle)
                        .foregroundStyle(PalTokens.textPrimary)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .hermesText(.rowSubtitle)
                            .foregroundStyle(PalTokens.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, PalMetrics.screenMargin)
            .frame(minHeight: PalMetrics.rowMinimumHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(ticked ? .isSelected : [])
        .accessibilityIdentifier("stepFlowConfirm-\(item.id)")
    }
}

struct StepSwitchGroups: View {
    let model: StepFlowModel
    let groups: [SetupSwitchGroup]

    @State private var asking: SetupSwitch?

    var body: some View {
        VStack(alignment: .leading, spacing: PalMetrics.screenMargin) {
            ForEach(groups) { group in groupView(group) }
        }
        .macAlert(item: $asking) { item in
            MacDialogContent(item.confirmTurningOff?.title ?? "", message: item.confirmTurningOff?.message ?? "", actions: [
                MacDialogAction(item.confirmTurningOff?.confirmTitle ?? "", role: .destructive) { model.setSwitch(item.id, false) },
                MacDialogAction(String(localized: "Cancel"), role: .cancel)
            ])
        }
    }

    @ViewBuilder
    private func groupView(_ group: SetupSwitchGroup) -> some View {
        VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
            if let header = group.header {
                Text(header)
                    .hermesText(.sectionCaption)
                    .textCase(.uppercase)
                    .foregroundStyle(PalTokens.textTertiary)
                    .padding(.horizontal, 4)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("stepFlowSwitchesHeader-\(group.id)")
            }
            if group.switches.isEmpty {
                if let note = group.emptyNote {
                    Text(note)
                        .hermesText(.rowSubtitle)
                        .foregroundStyle(PalTokens.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("stepFlowSwitchesEmpty-\(group.id)")
                }
            } else {
                StepChoiceCard(identifier: "stepFlowSwitches-\(group.id)") {
                    ForEach(Array(group.switches.enumerated()), id: \.element.id) { offset, item in
                        if offset > 0 { PalHairline() }
                        row(item)
                    }
                }
            }
        }
    }

    private func row(_ item: SetupSwitch) -> some View {
        let isOn = model.engine.isOn(item.id)
        let subtitle = isOn ? item.subtitle : (item.subtitleWhenOff ?? item.subtitle)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: PalMetrics.rowTextSpacing) {
                Text(item.title)
                    .hermesText(.rowTitle)
                    .foregroundStyle(PalTokens.textPrimary)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .hermesText(.rowSubtitle)
                        .foregroundStyle(PalTokens.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(item.title, isOn: Binding(get: { isOn }, set: { change(item, to: $0) }))
                .labelsHidden()
                .palSwitch()
                .accessibilityIdentifier("stepFlowSwitch-\(item.id)")
        }
        .padding(.leading, PalMetrics.screenMargin)
        .padding(.trailing, PalMetrics.screenMargin)
        .frame(minHeight: PalMetrics.rowMinimumHeight)
    }

    private func change(_ item: SetupSwitch, to on: Bool) {
        if !on, item.confirmTurningOff != nil {
            asking = item
        } else {
            model.setSwitch(item.id, on)
        }
    }
}
