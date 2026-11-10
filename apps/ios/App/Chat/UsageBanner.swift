import HermesDesign
import HermesSettings
import SwiftUI

struct UsageBanner: View {
    let notice: UsageNotice
    let review: () -> Void
    let dismiss: () -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.orange)
                    .accessibilityHidden(true)
                Text(notice.headline())
                    .font(.system(size: 13))
                    .foregroundStyle(PalTokens.textPrimary)
                    .accessibilityIdentifier("usageBannerTitle")
                Spacer(minLength: 8)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundStyle(PalTokens.textSecondary)
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
                    .buttonStyle(.palPill(height: 28, fontSize: 12.5, horizontalPadding: 14))
                    .accessibilityIdentifier("usageBannerReview")
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(PalTokens.elevated, in: shape)
        .overlay(shape.strokeBorder(PalTokens.panelBorder, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usageBanner")
    }
}
