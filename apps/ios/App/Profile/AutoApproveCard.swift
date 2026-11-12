import PalConnect
import PalDesign
import SwiftUI

struct AutoApproveCard: View {
    let sessionID: String?
    let upworkConnected: Bool

    @Environment(ActionAutoApprove.self) private var autoApprove
    @Environment(\.hermesTheme) private var theme

    var body: some View {
        if autoApprove.showsSwitch(sessionID: sessionID, upworkConnected: upworkConnected) {
            GroupedCard(accessibilityIdentifier: "autoApproveCard") {
                SettingsRow.toggle(
                    String(localized: "Approve Upwork actions automatically in this chat"),
                    isOn: Binding(
                        get: { autoApprove.entry(sessionID)?.enabled ?? false },
                        set: { value in Task { await autoApprove.setEnabled(value, sessionID: sessionID) } }
                    ),
                    minimumHeight: ProfileMetrics.toggleRowHeight,
                    accessibilityIdentifier: "autoApproveToggle"
                )
                .disabled(autoApprove.isPending(sessionID))
            }
            .padding(.top, ProfileMetrics.cardGap)
            Text(autoApprove.didFail(sessionID) ? String(localized: "Couldn't change this. Try again.") : String(localized: "Off by default. Applies to this chat only."))
                .hermesText(.footnoteCaption)
                .foregroundStyle(Color(theme.palette.sectionCaption))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PalMetrics.screenMargin + PalMetrics.rowInset)
                .padding(.top, ProfileMetrics.toggleToFooter)
                .accessibilityIdentifier("autoApproveFooter")
        }
    }
}
