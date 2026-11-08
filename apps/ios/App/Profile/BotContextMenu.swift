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
            ForEach(BotMenuAction.allCases) { action in
                if router.supports(action) {
                    Button(action.contextMenuTitle, systemImage: action.contextMenuSymbol) {
                        router.perform(action, botName: bot.name)
                    }
                    .accessibilityIdentifier("botMenu-\(action)")
                }
            }
            Button {
                roster.setPinned(bot, pinned: !bot.isPinned)
            } label: {
                Label(bot.isPinned ? "Unpin" : "Pin", systemImage: bot.isPinned ? "pin.slash" : "pin")
            }
            .accessibilityIdentifier(bot.isPinned ? "unpinAction" : "pinAction")
            if !bot.isPrimary {
                Button {
                    roster.makePrimary(bot)
                } label: {
                    Label("Make Primary", systemImage: "star")
                }
                .accessibilityIdentifier("makePrimaryAction")
            }
        }
    }
}
