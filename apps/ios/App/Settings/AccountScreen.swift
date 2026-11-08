import HermesDesign
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
            VStack(alignment: .leading, spacing: HermesMetrics.captionToCardGap) {
                SectionCaption("Switch Account", accessibilityIdentifier: "accountSwitchCaption")
                GroupedCard(accessibilityIdentifier: "accountSwitchCard") {
                    SettingsRow(
                        title: name, trailing: .none, accessibilityIdentifier: "accountSwitchCurrent"
                    )
                    .overlay(alignment: .trailing) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color(theme.palette.textPrimary))
                            .padding(.trailing, HermesMetrics.rowInset)
                            .accessibilityHidden(true)
                    }
                    LeadingSettingsRow(
                        title: "Add Account", leadingSpacing: 14, accessibilityIdentifier: "accountAddRow",
                        action: { confirmingAdd = true }
                    ) {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .light))
                            .foregroundStyle(Color(theme.palette.textPrimary))
                            .frame(width: 22)
                            .accessibilityHidden(true)
                    }
                }
            }
            GroupedCard(accessibilityIdentifier: "accountSignOutCard") {
                SettingsRow.destructive("Sign Out", accessibilityIdentifier: "accountSignOutRow", action: { confirmingSignOut = true })
            }
        }
        .confirmationDialog("Sign out of Hermes Bots on this device?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await connection.signOut() } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Signing in with another account replaces this one on this device.",
            isPresented: $confirmingAdd, titleVisibility: .visible
        ) {
            Button("Continue", role: .destructive) { Task { await connection.signOut() } }
            Button("Cancel", role: .cancel) {}
        }
    }
}
