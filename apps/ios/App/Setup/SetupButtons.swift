import PalDesign
import SwiftUI

struct SetupButton: View {
    enum Kind {
        case primary
        case secondary
    }

    let title: String
    var kind: Kind = .secondary
    var symbol: String?
    var isBusy = false
    var fillsWidth = false
    let identifier: String
    let action: () -> Void

    private var glass: Glass {
        switch kind {
        case .primary: Glass.regular.tint(PalTokens.toggleOn).interactive()
        case .secondary: Glass.regular.interactive()
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                label.opacity(isBusy ? 0 : 1)
                if isBusy { ProgressView().controlSize(.small) }
            }
            .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .buttonStyle(.glass(glass))
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
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(PalTokens.textSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}
