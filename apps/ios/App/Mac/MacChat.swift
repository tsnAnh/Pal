#if os(macOS)
import PalDesign
import PalRoster
import SwiftUI

struct MacChatHeader: View {
    let bot: BotRow
    let activity: BotActivity
    let mood: AvatarMood
    let router: AppRouter

    @Environment(MacShell.self) private var shell

    var body: some View {
        GlassEffectContainer(spacing: 24) {
            ZStack {
                Button { shell.toggleInspector() } label: {
                    HStack(spacing: 8) {
                        BotAvatarView(spec: bot.spec, size: 22 * 1.15, mood: mood)
                            .frame(width: 22, height: 22)
                            .opacity(activity.avatarOpacity)
                        Text(bot.displayName)
                            .hermesText(.botName)
                            .foregroundStyle(PalTokens.textPrimary)
                            .lineLimit(1)
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 12)
                    .frame(height: 34)
                    .palGlass(Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Bot details"))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(bot.displayName))
                .accessibilityValue(Text(activity.accessibilityValue))
                .accessibilityHint(Text("Shows details for this bot"))
                .accessibilityIdentifier("chatTitle")
                HStack {
                    Spacer()
                    if router.supports(.shareAsTemplate) {
                        Button { router.perform(.shareAsTemplate, botName: bot.name) } label: {
                            Text("Share")
                                .font(.system(size: 13))
                                .foregroundStyle(PalTokens.textPrimary)
                                .frame(width: 65, height: 33)
                                .palGlass(Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Share as Template…"))
                        .accessibilityLabel(Text("Share as Template"))
                        .accessibilityIdentifier("chatMenuShareTemplate")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: MacMetrics.topBarHeight)
    }
}

struct MacChatActions: ViewModifier {
    let find: () -> Void
    let focusComposer: () -> Void

    @Environment(MacShell.self) private var shell

    func body(content: Content) -> some View {
        content
            .onChange(of: shell.findToken) { find() }
            .onChange(of: shell.composerFocusToken) { focusComposer() }
    }
}
#endif
