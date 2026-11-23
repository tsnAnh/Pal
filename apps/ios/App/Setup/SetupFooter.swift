import PalDesign
import SwiftUI

private struct SetupFooterModifier: ViewModifier {
    let fillsWidth: Bool
    @Environment(\.hermesTheme) private var theme

    private var metrics: SetupFooterMetrics { SetupFooterMetrics.buttons(fillsWidth: fillsWidth) }

    func body(content: Content) -> some View {
        content
            .padding(metrics.insets)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .top) {
                LinearGradient(colors: [.clear, Color(theme.palette.sheetBackground)], startPoint: .top, endPoint: .bottom)
                    .frame(height: SetupFooterMetrics.fadeHeight)
                    .offset(y: -SetupFooterMetrics.fadeHeight)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

extension View {
    func setupFooter(fillsWidth: Bool) -> some View {
        modifier(SetupFooterModifier(fillsWidth: fillsWidth))
    }
}
