import PalDesign
import SwiftUI

struct SlackGroup<Content: View>: View {
    let caption: String?
    let footer: String?
    let identifier: String
    @ViewBuilder let content: () -> Content

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
            if let caption {
                SectionCaption(caption, accessibilityIdentifier: "\(identifier)Caption")
                    .padding(.horizontal, PalMetrics.captionInset)
            }
            SlackCard { content() }
            if let footer {
                Text(footer)
                    .hermesText(.footnoteCaption)
                    .foregroundStyle(Color(theme.palette.sectionCaption))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, PalMetrics.captionInset)
                    .accessibilityIdentifier("\(identifier)Footer")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

private extension PalMetrics {
    static let captionInset: CGFloat = 4
}

struct SlackChoiceRow: View {
    let icon: String
    let title: String
    let detail: String?
    let isSelected: Bool
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                PalIcon(icon, ink: .secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: PalMetrics.rowTextSpacing) {
                    Text(title).hermesText(.rowTitle).foregroundStyle(PalTokens.textPrimary).lineLimit(2)
                    if let detail {
                        Text(detail)
                            .hermesText(.rowSubtitle)
                            .foregroundStyle(PalTokens.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                PalIcon("checkmark", ink: .primary)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(PalMetrics.screenMargin)
            .frame(minHeight: PalMetrics.rowMinimumHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier)
    }
}

struct PersonBadge: View {
    let name: String
    var size: CGFloat = 28

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2).compactMap(\.first)
        return String(parts).uppercased()
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(PalTokens.textPrimary)
            .frame(width: size, height: size)
            .background(PalTokens.control, in: Circle())
            .accessibilityHidden(true)
    }
}

struct SlackNotice: View {
    let text: String
    let identifier: String

    var body: some View {
        Text(text)
            .hermesText(.rowSubtitle)
            .foregroundStyle(PalTokens.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
    }
}
