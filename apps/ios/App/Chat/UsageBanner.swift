import PalDesign
import PalSettings
import SwiftUI

struct UsageBanner: View {
    let notice: UsageNotice
    let review: () -> Void
    let dismiss: () -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                PalIcon("exclamationmark.triangle.fill", ink: .custom(.orange))
                    .font(.system(size: 12))
                    .accessibilityHidden(true)
                Text(notice.headline())
                    .font(.system(size: 13))
                    .foregroundStyle(PalTokens.textPrimary)
                    .accessibilityIdentifier("usageBannerTitle")
                Spacer(minLength: 8)
                Button(action: dismiss) {
                    PalIcon("xmark", ink: .secondary)
                        .font(.system(size: 10))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Dismiss"))
                .accessibilityLabel(Text("Dismiss"))
                .accessibilityIdentifier("usageBannerDismiss")
            }
            if let reset = notice.resetLine(now: Date()) {
                Text(reset)
                    .font(.system(size: 12))
                    .foregroundStyle(PalTokens.textSecondary)
                    .padding(.leading, 21)
                    .accessibilityIdentifier("usageBannerReset")
            }
            HStack {
                Spacer()
                Button("Review Usage", action: review)
                    .glassButtonStyle()
                    .accessibilityIdentifier("usageBannerReview")
            }
            .padding(.top, 4)
        }
        .padding(12)
        .background(PalTokens.elevated, in: shape)
        .overlay(shape.strokeBorder(PalTokens.panelBorder, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usageBanner")
    }
}
