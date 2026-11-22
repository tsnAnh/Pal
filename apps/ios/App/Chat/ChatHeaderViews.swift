import PalChat
import PalConnect
import PalDesign
import PalRoster
import SwiftUI

struct ChatBotScope: ViewModifier {
    let model: ChatModel
    let intake: IntakeHandler

    @Environment(ActionAutoApprove.self) private var autoApprove

    func body(content: Content) -> some View {
        content
            .attachmentIntake(botName: model.bot.displayName, accent: model.chatAccent, intake: intake)
            .environment(\.chatInk, BubblePalette.ink(accent: model.chatAccent))
            .task(id: model.bot.conversationID) { await autoApprove.load(sessionID: model.bot.conversationID) }
    }
}

struct ChatTitleButton: View {
    let model: ChatModel
    let router: AppRouter

    var body: some View {
        Button { router.perform(.viewProfile, botName: model.bot.name) } label: {
            BotCapsule(bot: model.bot, activity: model.activity, mood: model.avatarMood)
        }
        .buttonStyle(.plain)
        .disabled(!router.supports(.viewProfile))
        .accessibilityHint(Text("Shows this bot's profile"))
        .accessibilityIdentifier("chatTitle")
    }
}

struct ChatOptionsMenu: View {
    let model: ChatModel
    let router: AppRouter
    var focused: FocusState<Bool>.Binding

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        Menu {
            if router.supports(.viewProfile) {
                Button { router.perform(.viewProfile, botName: model.bot.name) } label: {
                    Label("View Profile", palIcon: "person.crop.circle")
                }
                .accessibilityIdentifier("chatMenuViewProfile")
            }
            Button {
                focused.wrappedValue = false
                model.beginFinding()
            } label: {
                Label("Find in Chat", palIcon: "magnifyingglass")
            }
            .accessibilityIdentifier("chatMenuFind")
            if router.supports(.shareAsTemplate) {
                Button { router.perform(.shareAsTemplate, botName: model.bot.name) } label: {
                    Label("Share as Template…", palIcon: "square.and.arrow.up")
                }
                .accessibilityIdentifier("chatMenuShareTemplate")
            }
        } label: {
            PalIcon("ellipsis")
                .accessibilityLabel(Text("Chat options"))
        }
        .tint(Color(theme.palette.textPrimary))
        .accessibilityIdentifier("chatMenuButton")
    }
}

#if os(macOS)
struct ChatMacHeaderHost: View {
    let model: ChatModel

    var body: some View {
        MacChatHeader(bot: model.bot, activity: model.activity, mood: model.avatarMood)
    }
}
#endif

private struct BotCapsule: View {
    @Environment(\.hermesTheme) private var theme

    let bot: BotRow
    let activity: BotActivity
    let mood: AvatarMood

    var body: some View {
        HStack(spacing: 9) {
            BotAvatarView(spec: bot.spec, size: ChatMetrics.headerAvatarSize, mood: mood)
                .opacity(activity.avatarOpacity)
            Text(bot.displayName)
                .hermesText(.botName)
                .foregroundStyle(Color(theme.palette.textPrimary))
                .lineLimit(1)
        }
        .padding(.horizontal, 13)
        .frame(height: ChatMetrics.headerButtonDiameter)
        .palGlass(Capsule(), interactive: true)
        .contentShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(bot.displayName))
        .accessibilityValue(Text(activity.accessibilityValue))
    }
}
