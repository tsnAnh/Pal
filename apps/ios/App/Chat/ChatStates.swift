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
            Button(suggestion, action: send)
                .glassButtonStyle()
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
            PalIcon("exclamationmark.circle", ink: .secondary)
                .font(.system(size: ChatMetrics.statusIconSize, weight: .medium))
                .accessibilityHidden(true)
            Text(text)
                .hermesText(.timestamp)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("composerNoticeText")
            Button(action: dismiss) {
                PalIcon("xmark", ink: .secondary)
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
