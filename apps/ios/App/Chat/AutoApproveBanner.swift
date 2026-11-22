import PalConnect
import PalDesign
import SwiftUI

struct AutoApproveBanner: View {
    let sessionID: String?

    @Environment(ActionAutoApprove.self) private var autoApprove

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    var body: some View {
        if autoApprove.showsBanner(sessionID: sessionID) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 9) {
                    PalIcon("checkmark.shield", ink: .secondary)
                        .font(.system(size: 12))
                        .accessibilityHidden(true)
                    Text("Upwork actions are approved automatically in this chat")
                        .font(.system(size: 13))
                        .foregroundStyle(PalTokens.textPrimary)
                        .accessibilityIdentifier("autoApproveBannerTitle")
                    Spacer(minLength: 8)
                    Button("Off") { Task { await autoApprove.setEnabled(false, sessionID: sessionID) } }
                        .buttonStyle(.glass)
                        .disabled(autoApprove.isPending(sessionID))
                        .accessibilityIdentifier("autoApproveBannerOff")
                }
                if autoApprove.didFail(sessionID) {
                    Text("Couldn't turn it off. Try again.")
                        .font(.system(size: 12))
                        .foregroundStyle(PalTokens.textSecondary)
                        .padding(.leading, 21)
                        .accessibilityIdentifier("autoApproveBannerError")
                }
            }
            .padding(12)
            .background(PalTokens.elevated, in: shape)
            .overlay(shape.strokeBorder(PalTokens.panelBorder, lineWidth: 1))
            .padding(.horizontal, ChatMetrics.edgeMargin)
            .padding(.top, 6)
            .chatColumn()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("autoApproveBanner")
        }
    }
}
