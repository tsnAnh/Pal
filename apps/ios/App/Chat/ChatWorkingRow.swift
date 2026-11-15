import PalDesign
import SwiftUI

struct ChatWorkingRow: View {
    let status: String?
    let ink: Color

    private var text: String { status ?? String(localized: "Thinking") }

    var body: some View {
        HStack(spacing: ChatMetrics.statusTextGap) {
            Circle()
                .fill(ink)
                .frame(width: ChatMetrics.workingDotDiameter, height: ChatMetrics.workingDotDiameter)
                .accessibilityHidden(true)
            Text(text)
                .hermesText(.chatBody)
                .foregroundStyle(PalTokens.textSecondary)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.15), value: text)
                .accessibilityIdentifier(status == nil ? "thinkingLine" : "workingStatus")
        }
        .padding(.leading, ChatMetrics.statusLeadingInset - ChatMetrics.edgeMargin)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Thinking"))
        .accessibilityIdentifier("assistantBubble-streaming")
    }
}
