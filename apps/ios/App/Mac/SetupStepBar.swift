#if os(macOS)
import PalDesign
import SwiftUI

struct SetupStepBar: View {
    static let height: CGFloat = 4
    static let spacing: CGFloat = 6

    let step: Int
    let total: Int
    var identifier = "setupStepBar"

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(1...max(total, 1), id: \.self) { index in
                Capsule()
                    .fill(index <= step ? PalTokens.textPrimary : PalTokens.borderStrong)
                    .frame(height: Self.height)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(step) of \(total)"))
        .accessibilityIdentifier(identifier)
    }
}
#endif
