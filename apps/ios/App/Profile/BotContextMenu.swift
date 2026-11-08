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
    func botContextMenu(botName: String, router: AppRouter) -> some View {
        contextMenu {
            ForEach(BotMenuAction.allCases) { action in
                if router.supports(action) {
                    Button(action.contextMenuTitle, systemImage: action.contextMenuSymbol) {
                        router.perform(action, botName: botName)
                    }
                    .accessibilityIdentifier("botMenu-\(action)")
                }
            }
        }
    }
}
