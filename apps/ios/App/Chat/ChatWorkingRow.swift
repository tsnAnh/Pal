import HermesDesign
import SwiftUI

struct ChatWorkingRow: View {
    let status: String?
    let accent: BotAccent?

    @Environment(\.hermesTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var text: String { status ?? String(localized: "Putting it together") }

    private var dotColor: Color {
        guard let accent else { return Color(theme.palette.workingDot) }
        if colorScheme == .light, AvatarColor(css: accent.accentHex)?.isWhite == true { return Color(theme.palette.textSecondary) }
        return accent.accent
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 8) {
                dots(at: time)
                    .accessibilityHidden(true)
                Text(text)
                    .hermesText(.chatBody)
                    .foregroundStyle(shimmer(at: time))
                    .lineLimit(1)
                    .accessibilityIdentifier(status == nil ? "thinkingLine" : "workingStatus")
            }
        }
        .padding(.leading, 6.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Thinking"))
        .accessibilityIdentifier("assistantBubble-streaming")
    }

    private func dots(at time: TimeInterval) -> some View {
        HStack(spacing: 4.5) {
            ForEach(0..<3, id: \.self) { index in
                let cycle = reduceMotion ? 0.5 : (time * 1.6 - Double(index) * 0.33).truncatingRemainder(dividingBy: 1)
                let wrapped = cycle < 0 ? cycle + 1 : cycle
                let pulse = max(0, sin(wrapped * .pi))
                Circle()
                    .fill(dotColor.opacity(0.45 + 0.55 * pulse))
                    .frame(width: 6, height: 6)
                    .scaleEffect(1 + 0.4 * pulse)
            }
        }
        .frame(width: 6 * 3 + 4.5 * 2 + 4, height: 12)
    }

    private func shimmer(at time: TimeInterval) -> LinearGradient {
        let center = reduceMotion ? 0.5 : (time.truncatingRemainder(dividingBy: 2.2) / 2.2) * 1.8 - 0.4
        return LinearGradient(
            colors: [PalTokens.textSecondary, PalTokens.textTertiary.opacity(0.7), PalTokens.textSecondary],
            startPoint: UnitPoint(x: center - 0.3, y: 0.5),
            endPoint: UnitPoint(x: center + 0.3, y: 0.5)
        )
    }
}
