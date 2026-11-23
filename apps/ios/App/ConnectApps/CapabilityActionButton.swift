import PalDesign
import SwiftUI

struct CapabilityActionLabel: View {
    let title: String
    var isBusy = false

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ZStack {
            Text(title).opacity(isBusy ? 0 : 1)
            if isBusy { ProgressView().controlSize(.small) }
        }
        .capabilityActionLabel(CapabilityMetrics.metrics(sizeClass: sizeClass))
    }
}

struct CapabilityActionButton: View {
    let title: String
    var isBusy = false
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { CapabilityActionLabel(title: title, isBusy: isBusy) }
            .glassButtonStyle()
            .disabled(isBusy)
            .accessibilityLabel(Text(title))
            .accessibilityIdentifier(identifier)
    }
}

struct AddCustomConnectorButton: View {
    let action: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .body) private var iconSize = CapabilityMetrics.addIconSize

    var body: some View {
        Button(action: action) {
            HStack(spacing: CapabilityMetrics.addIconGap) {
                PalIcon("plus")
                    .font(.system(size: iconSize, weight: .semibold))
                    .accessibilityHidden(true)
                Text("Add a custom connector")
            }
            .capabilityAddLabel(CapabilityMetrics.metrics(sizeClass: sizeClass))
        }
        .glassButtonStyle()
        .accessibilityIdentifier("addCustomConnectorButton")
        .padding(.top, CapabilityMetrics.addTopGap)
        .padding(.horizontal, PalMetrics.screenMargin)
    }
}
