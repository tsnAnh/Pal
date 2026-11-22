import PalBotProfile
import PalDesign
import PalDiagnostics
import SwiftUI

struct MacLibraryRow: View, Equatable {
    let item: MacLibraryRowItem
    let isPreparing: Bool
    let model: LibraryModel

    private static let cornerRadius: CGFloat = 12

    nonisolated static func == (lhs: MacLibraryRow, rhs: MacLibraryRow) -> Bool {
        lhs.item == rhs.item && lhs.isPreparing == rhs.isPreparing
    }

    var body: some View {
        let _ = PalPerf.event("library.row.body") // swiftlint:disable:this redundant_discardable_let
        if item.isFirst {
            row
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("libraryCard-\(item.groupID)")
        } else {
            row
        }
    }

    @ViewBuilder
    private var row: some View {
        let entry = item.entry
        Group {
            if entry.isOpenable {
                Button { model.open(entry) } label: { rowContent }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("libraryRow-\(entry.id)")
                    .accessibilityValue(Text(entry.kind.rawValue))
            } else {
                rowContent
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("libraryRow-\(entry.id)")
                    .accessibilityValue(Text(entry.kind.rawValue))
            }
        }
        .background(PalTokens.elevated, in: shape)
    }

    private var shape: UnevenRoundedRectangle {
        let top = item.isFirst ? Self.cornerRadius : 0
        let bottom = item.isLast ? Self.cornerRadius : 0
        return UnevenRoundedRectangle(
            topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous
        )
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            LibraryIcon(entry: item.entry, model: model, size: 20, glyph: 12)
                .frame(width: 20, height: 20)
            Text(item.entry.title)
                .font(.system(size: 12))
                .foregroundStyle(PalTokens.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if isPreparing {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 33)
        .contentShape(Rectangle())
        .help(item.subtitle)
    }
}
