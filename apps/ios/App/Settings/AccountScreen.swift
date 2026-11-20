import PalDesign
import SwiftUI

struct AccountScreen: View {
    let connection: ConnectionModel
    let back: () -> Void

    @Environment(\.hermesTheme) private var theme
    @State private var confirmingSignOut = false
    @State private var confirmingAdd = false

    private var name: String { connection.userName.isEmpty ? "Account" : connection.userName }

    var body: some View {
        SettingsPage(title: "Account", identifier: "accountScreen", back: back) {
            GroupedCard(accessibilityIdentifier: "accountCurrentCard") {
                LeadingSettingsRow(
                    title: name, subtitle: connection.gatewayHost, accessibilityIdentifier: "accountCurrentRow"
                ) {
                    InitialAvatar(initial: connection.userInitial)
                }
                .frame(minHeight: 70)
            }
            VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
                SectionCaption("Switch Account", accessibilityIdentifier: "accountSwitchCaption")
                GroupedCard(accessibilityIdentifier: "accountSwitchCard") {
                    SettingsRow(
                        title: name, trailing: .none, accessibilityIdentifier: "accountSwitchCurrent"
                    )
                    .overlay(alignment: .trailing) {
                        PalIcon("checkmark")
                            .font(.system(size: 16, weight: .medium))
                            .padding(.trailing, PalMetrics.rowInset)
                            .accessibilityHidden(true)
                    }
                    LeadingSettingsRow(
                        title: "Add Account", leadingSpacing: 14, accessibilityIdentifier: "accountAddRow",
                        action: { confirmingAdd = true }
                    ) {
                        PalIcon("plus")
                            .font(.system(size: 20, weight: .light))
                            .frame(width: 22)
                            .accessibilityHidden(true)
                    }
                }
            }
            GroupedCard(accessibilityIdentifier: "accountSignOutCard") {
                SettingsRow.destructive("Sign Out", accessibilityIdentifier: "accountSignOutRow", action: { confirmingSignOut = true })
            }
        }
        .macConfirm(isPresented: $confirmingSignOut) {
            MacDialogContent(
                String(localized: "Sign out of Pal on this device?"),
                actions: [
                    MacDialogAction("Sign Out", role: .destructive) { Task { await connection.signOut() } },
                    MacDialogAction("Cancel", role: .cancel),
                ]
            )
        }
        .macConfirm(isPresented: $confirmingAdd) {
            MacDialogContent(
                String(localized: "Signing in with another account replaces this one on this device."),
                actions: [
                    MacDialogAction("Continue", role: .destructive) { Task { await connection.signOut() } },
                    MacDialogAction("Cancel", role: .cancel),
                ]
            )
        }
    }
}
