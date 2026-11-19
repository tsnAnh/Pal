import PalDesign
import SwiftUI

extension BotMenuAction {
    var contextMenuTitle: LocalizedStringKey {
        switch self {
        case .viewProfile: "View Profile"
        case .shareAsTemplate: "Share as Template…"
        }
    }

    var contextMenuSymbol: String {
        switch self {
        case .viewProfile: "person.crop.circle"
        case .shareAsTemplate: "square.and.arrow.up"
        }
    }
}

extension View {
    func botContextMenu(_ bot: BotRow, roster: RosterModel, router: AppRouter) -> some View {
        contextMenu {
            Group {
                pinButton(bot, roster: roster)
                unreadButton(bot, roster: roster)
                Divider()
                if !bot.isPrimary {
                    renameButton(bot, router: router)
                    Divider()
                }
                copyIDButton(bot, roster: roster)
                Divider()
                visibilityButton(bot, roster: roster)
                if bot.isPrimary {
                    replacePrimaryMenu(roster: roster)
                } else {
                    deleteButton(bot, router: router)
                }
                Divider()
                actionButtons(bot, router: router)
                makePrimaryButton(bot, roster: roster)
            }
            .labelStyle(.titleAndIcon)
            .macOnly { $0.tint(PalTokens.textSecondary) }
        }
    }

    @ViewBuilder
    private func actionButtons(_ bot: BotRow, router: AppRouter) -> some View {
        ForEach(BotMenuAction.allCases) { action in
            if router.supports(action) {
                Button {
                    router.perform(action, botName: bot.name)
                } label: {
                    Label(action.contextMenuTitle, palIcon: action.contextMenuSymbol)
                }
                .accessibilityIdentifier("botMenu-\(action)")
            }
        }
    }

    private func pinButton(_ bot: BotRow, roster: RosterModel) -> some View {
        Button {
            roster.setPinned(bot, pinned: !bot.isPinned)
        } label: {
            Label(bot.isPinned ? "Unpin" : "Pin", palIcon: bot.isPinned ? "pin.slash" : "pin")
        }
        .accessibilityIdentifier(bot.isPinned ? "unpinAction" : "pinAction")
    }

    private func unreadButton(_ bot: BotRow, roster: RosterModel) -> some View {
        Button {
            if bot.isUnread { roster.markRead(bot.name) } else { roster.markUnread(bot) }
        } label: {
            Label(bot.isUnread ? "Mark as Read" : "Mark as Unread", palIcon: bot.isUnread ? "bell.slash" : "bell")
        }
        .accessibilityIdentifier(bot.isUnread ? "markReadAction" : "markUnreadAction")
    }

    private func renameButton(_ bot: BotRow, router: AppRouter) -> some View {
        Button {
            router.renamingBot = bot.name
        } label: {
            Label("Rename Bot", palIcon: "square.and.pencil")
        }
        .accessibilityIdentifier("renameBotAction")
    }

    @ViewBuilder
    private func copyIDButton(_ bot: BotRow, roster: RosterModel) -> some View {
        if bot.conversationID != nil {
            Button {
                roster.copyConversationID(bot)
            } label: {
                Label("Copy conversation ID", palIcon: "doc.on.doc")
            }
            .accessibilityIdentifier("copyConversationIDAction")
        }
    }

    private func visibilityButton(_ bot: BotRow, roster: RosterModel) -> some View {
        Button {
            roster.setHidden(bot, hidden: !bot.isHidden)
        } label: {
            Label(visibilityTitle(hidden: bot.isHidden), palIcon: bot.isHidden ? "eye" : "eye.slash")
        }
        .accessibilityIdentifier(bot.isHidden ? "showBotAction" : "hideBotAction")
    }

    private func visibilityTitle(hidden: Bool) -> String {
        PlatformVariant.pick(
            mac: hidden ? String(localized: "Show in sidebar") : String(localized: "Hide from sidebar"),
            iOS: hidden ? String(localized: "Show in list") : String(localized: "Hide from list")
        )
    }

    private func deleteButton(_ bot: BotRow, router: AppRouter) -> some View {
        Button(role: .destructive) {
            router.deletingBot = bot.name
        } label: {
            Label("Delete", palIcon: "trash", ink: .destructive)
        }
        .accessibilityIdentifier("deleteBotAction")
    }

    @ViewBuilder
    private func replacePrimaryMenu(roster: RosterModel) -> some View {
        if !roster.replacementPrimaries.isEmpty {
            Menu {
                ForEach(roster.replacementPrimaries) { candidate in
                    Button(candidate.displayName) { roster.makePrimary(candidate) }
                        .accessibilityIdentifier("replacePrimary-\(candidate.name)")
                }
            } label: {
                Label("Replace with different Bot", palIcon: "arrow.left.arrow.right")
            }
            .accessibilityIdentifier("replacePrimaryMenu")
        }
    }

    @ViewBuilder
    private func makePrimaryButton(_ bot: BotRow, roster: RosterModel) -> some View {
        if !bot.isPrimary {
            Button {
                roster.makePrimary(bot)
            } label: {
                Label("Make Primary", palIcon: "star")
            }
            .accessibilityIdentifier("makePrimaryAction")
        }
    }
}
