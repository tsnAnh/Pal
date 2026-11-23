import PalDesign
import SwiftUI

struct SlackHeader: View {
    let spec: BotAvatarSpec?
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                if let spec {
                    BotAvatarView(spec: spec, size: 64, animated: false)
                }
                PalIcon("number", ink: .secondary)
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(PalTokens.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(PalTokens.borderStrong, lineWidth: PalMetrics.separatorThickness)
                    }
                    .accessibilityHidden(true)
            }
            Text(title)
                .hermesText(.sheetTitle)
                .foregroundStyle(PalTokens.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("slackTitle")
            Text(value)
                .hermesText(.rowTitle)
                .foregroundStyle(PalTokens.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("slackBody")
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    static func title(name: String, finished: Bool) -> String {
        finished ? String(localized: "\(name) is in Slack") : String(localized: "Add \(name) to Slack")
    }

    static func value(name: String, finished: Bool) -> String {
        finished
            ? String(localized: "You can DM or @mention \(name) in Slack.")
            : String(localized: "DM or @mention \(name) in Slack. It answers with the same plugins, context and memories as here.")
    }
}
