import PalDesign
import SwiftUI

struct NewChatIntro: View {
    let bot: BotRow
    let mood: AvatarMood
    let suggestion: String
    let send: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            BotAvatarView(spec: bot.spec, size: 56, mood: mood)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(bot.displayName)
                    .hermesText(.chatBody)
                    .fontWeight(.semibold)
                    .foregroundStyle(PalTokens.textPrimary)
                Text("Ask for anything. You'll see each step here while \(bot.displayName) works.")
                    .hermesText(.chatStatus)
                    .foregroundStyle(PalTokens.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            Button(action: send) {
                Text(suggestion)
                    .hermesText(.chatStatus)
                    .foregroundStyle(PalTokens.textPrimary)
                    .padding(.horizontal, 16)
                    .frame(minHeight: ChatMetrics.minimumHitTarget)
                    .background(PalTokens.chipFill, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            .accessibilityHint(Text("Sends this message"))
            .accessibilityIdentifier("newChatSuggestion")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("newChatIntro")
    }
}

struct ComposerNotice: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: ChatMetrics.statusIconSize, weight: .medium))
                .accessibilityHidden(true)
            Text(text)
                .hermesText(.timestamp)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("composerNoticeText")
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: ChatMetrics.minimumHitTarget, height: ChatMetrics.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
            .accessibilityIdentifier("composerNoticeDismiss")
        }
        .foregroundStyle(PalTokens.textSecondary)
        .padding(.leading, 8)
        .frame(minHeight: ChatMetrics.minimumHitTarget)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composerNotice")
    }
}

extension EnvironmentValues {
    @Entry var chatInk: Color = PalTokens.inverseFill
}

struct FindMark {
    let ink: Color
    let surfaceText: Color?
    let isCurrent: Bool

    var fill: Color { (surfaceText ?? ink).opacity(isCurrent ? 0.5 : 0.22) }
    var text: Color? { isCurrent && surfaceText == nil ? PalTokens.textPrimary : nil }
}

struct SendRise: ViewModifier {
    let isFresh: Bool

    @State private var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lifted: Bool { isFresh && !settled && !reduceMotion }

    func body(content: Content) -> some View {
        content
            .offset(y: lifted ? Self.rise : 0)
            .opacity(lifted ? 0 : 1)
            .onAppear {
                guard lifted else { return }
                withAnimation(.easeOut(duration: Self.duration)) { settled = true }
            }
    }

    private static let rise: CGFloat = 8
    private static let duration = 0.18
}
