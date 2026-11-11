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

    #if os(iOS)
    @State private var proposedName = ""
    @State private var renamingTarget: BotRow?
    #endif

    private var deletingBot: BotRow? { router.deletingBot.flatMap { roster.bot(named: $0) } }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                Text("Delete \(deletingBot?.displayName ?? "this bot")?"),
                isPresented: Binding(get: { deletingBot != nil }, set: { if !$0 { router.deletingBot = nil } }),
                titleVisibility: .visible,
                presenting: deletingBot
            ) { bot in
                Button("Delete", role: .destructive) { Task { await roster.delete(bot) } }
                    .accessibilityIdentifier("deleteBotConfirm")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Its conversation and settings are removed from all your devices. This can't be undone.")
            }
            .alert(
                Text("Couldn't update the bot"),
                isPresented: Binding(get: { roster.adminError != nil }, set: { if !$0 { roster.dismissAdminError() } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(AdminErrorCopy.message(roster.adminError))
            }
            #if os(iOS)
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
            #endif
    }

    #if os(iOS)
    private func renameCurrent() {
        guard let bot = renamingTarget else { return }
        let name = proposedName
        Task {
            do { try await roster.rename(bot, to: name) } catch is CancellationError {} catch { roster.report(error) }
        }
    }
    #endif
}
