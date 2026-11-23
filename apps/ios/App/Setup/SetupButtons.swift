import PalDesign
import SwiftUI

struct SetupButton: View {
    enum Kind {
        case primary
        case secondary

        fileprivate var role: SetupButtonRole { self == .primary ? .primary : .secondary }
    }

    let title: String
    var kind: Kind = .secondary
    var symbol: String?
    var isBusy = false
    var fillsWidth = false
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                label.opacity(isBusy ? 0 : 1)
                if isBusy { ProgressView().controlSize(.small) }
            }
            .setupButtonLabel(SetupFooterMetrics.buttons(fillsWidth: fillsWidth), role: kind.role, fillsWidth: fillsWidth)
        }
        .glassButtonStyle(prominent: kind == .primary)
        .disabled(isBusy)
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var label: some View {
        if let symbol {
            Label(title, palIcon: symbol)
        } else {
            Text(title)
        }
    }
}

struct SetupQuietButton: View {
    let title: String
    var fillsWidth = false
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(PalTokens.textSecondary)
                .setupButtonLabel(SetupFooterMetrics.buttons(fillsWidth: fillsWidth), role: .quiet, fillsWidth: fillsWidth)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}
