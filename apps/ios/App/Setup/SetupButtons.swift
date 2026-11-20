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

    @Environment(\.controlSize) private var controlSize

    private var isCompact: Bool { controlSize == .small }

    private var capsule: PalClearCapsuleStyle {
        PalClearCapsuleStyle(
            height: isCompact ? 30 : 38, horizontalPadding: isCompact ? 14 : 18, selected: kind == .primary, fillsWidth: fillsWidth
        )
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                label.opacity(isBusy ? 0 : 1)
                if isBusy { ProgressView().controlSize(.small) }
            }
        }
        .buttonStyle(capsule)
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
