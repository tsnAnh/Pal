import SwiftUI

public struct UsageGaugeRow: View {
    public let title: String
    public let caption: String?
    public let fraction: Double
    public let valueText: String
    public let accessibilityIdentifier: String

    @Environment(\.hermesTheme) private var theme

    public init(title: String, caption: String? = nil, fraction: Double, valueText: String, accessibilityIdentifier: String) {
        self.title = title
        self.caption = caption
        self.fraction = fraction
        self.valueText = valueText
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .hermesText(.rowTitle)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let caption {
                    Text(caption)
                        .hermesText(.rowSubtitle)
                        .foregroundStyle(Color(theme.palette.textSecondary).opacity(0.55))
                        .lineLimit(1)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(theme.palette.toggleOffTrack))
                    Capsule()
                        .fill(Color(theme.palette.accentBlue))
                        .frame(width: max(fraction > 0 ? 6 : 0, proxy.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 6)
            Text(valueText)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color(theme.palette.textSecondary))
        }
        .padding(.horizontal, HermesMetrics.rowInset)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text([valueText, caption].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
