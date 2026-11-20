import PalDesign
import PalRoster
import SwiftUI

extension View {
    func botManagementDialogs(roster: RosterModel, router: AppRouter) -> some View {
        modifier(BotManagementDialogs(roster: roster, router: router))
    }
}

private struct BotManagementDialogs: ViewModifier {
    let roster: RosterModel
    @Bindable var router: AppRouter

    @State private var proposedName = ""
    @State private var renamingTarget: BotRow?

    private var deletingBot: BotRow? { router.deletingBot.flatMap { roster.bot(named: $0) } }

    func body(content: Content) -> some View {
        content
            .macConfirm(item: Binding(get: { deletingBot }, set: { if $0 == nil { router.deletingBot = nil } })) { bot in
                MacDialogContent(
                    String(localized: "Delete \(bot.displayName)?"),
                    message: String(localized: "Its conversation and settings are removed from all your devices. This can't be undone."),
                    actions: [
                        MacDialogAction(String(localized: "Delete"), role: .destructive, identifier: "deleteBotConfirm") {
                            Task { await roster.delete(bot) }
                        },
                        MacDialogAction(String(localized: "Cancel"), role: .cancel),
                    ]
                )
            }
            .macAlert(isPresented: Binding(get: { roster.adminError != nil }, set: { if !$0 { roster.dismissAdminError() } })) {
                MacDialogContent(
                    String(localized: "Couldn't update the bot"),
                    message: AdminErrorCopy.message(roster.adminError),
                    actions: [MacDialogAction(String(localized: "OK"), role: .cancel)]
                )
            }
            .iOSOnly { view in
                view
                    .alert(
                        Text("Rename Bot"),
                        isPresented: Binding(get: { router.renamingBot != nil }, set: { if !$0 { router.renamingBot = nil } })
                    ) {
                        TextField("Name", text: $proposedName)
                        Button("Cancel", role: .cancel) {}
                        Button("Save") { renameCurrent() }
                    }
                    .onChange(of: router.renamingBot) { _, name in
                        renamingTarget = name.flatMap { roster.bot(named: $0) }
                        proposedName = renamingTarget?.displayName ?? ""
                    }
            }
    }

    private func renameCurrent() {
        guard let bot = renamingTarget else { return }
        let name = proposedName
        Task {
            do { try await roster.rename(bot, to: name) } catch is CancellationError {} catch { roster.report(error) }
        }
    }
}

