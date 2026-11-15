import PalDesign
import SwiftUI

struct ChatWorkingRow: View {
    let status: String?
    let ink: Color
    var avatar: BotAvatarSpec?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mood = AvatarMood.think

    private var text: String { status ?? String(localized: "Thinking") }

    var body: some View {
        HStack(spacing: ChatMetrics.statusTextGap) {
            if let avatar {
                BotAvatarView(spec: avatar, size: ChatMetrics.workingAvatarSize, mood: reduceMotion ? .think : mood)
                    .accessibilityHidden(true)
                    .task(id: reduceMotion) { await cycleMood() }
            }
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(text)
                    .hermesText(.chatBody)
                    .foregroundStyle(PalTokens.textSecondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.2), value: text)
                    .accessibilityIdentifier(status == nil ? "thinkingLine" : "workingStatus")
                WorkingDots(ink: ink, animated: !reduceMotion)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, avatar == nil ? ChatMetrics.statusLeadingInset - ChatMetrics.edgeMargin : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Thinking"))
        .accessibilityValue(Text(status ?? ""))
        .accessibilityIdentifier("assistantBubble-streaming")
    }

    private func cycleMood() async {
        guard !reduceMotion else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(ChatMetrics.workingMoodPeriod))
            mood = mood == .think ? .work : .think
        }
    }
}

private struct WorkingDots: View {
    let ink: Color
    let animated: Bool

    private static let period = 1.2
    private static let stagger = 0.16
    private static let diameter: CGFloat = 4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    let lift = animated ? Self.lift(at: time - Double(index) * Self.stagger) : 1
                    Circle()
                        .fill(ink)
                        .frame(width: Self.diameter, height: Self.diameter)
                        .opacity(0.3 + 0.7 * lift)
                        .offset(y: -2 * lift)
                }
            }
        }
        .frame(height: Self.diameter + 2, alignment: .bottom)
    }

    private static func lift(at time: TimeInterval) -> Double {
        let phase = time.truncatingRemainder(dividingBy: period) / period
        let wrapped = phase < 0 ? phase + 1 : phase
        guard wrapped < 0.5 else { return 0 }
        return sin(wrapped * 2 * .pi)
    }
}
