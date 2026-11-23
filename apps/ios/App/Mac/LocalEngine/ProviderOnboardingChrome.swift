#if os(macOS)
import PalDesign
import SwiftUI

struct ProviderOnboardingTopBar: View {
    let title: String
    let titleIdentifier: String
    let leading: SheetLeadingButton
    let isEnabled: Bool
    let action: () -> Void

    private var barHeight: CGFloat { PalMetrics.macPanelCloseTopInset * 2 + PalMetrics.sheetGlassButtonSize }

    private var titleClearance: CGFloat { PalMetrics.macPanelCloseLeadingInset * 2 + PalMetrics.sheetGlassButtonSize }

    var body: some View {
        Text(title)
            .hermesText(.sheetTitle)
            .foregroundStyle(PalTokens.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(titleIdentifier)
            .padding(.horizontal, titleClearance)
            .frame(maxWidth: .infinity)
            .frame(height: barHeight)
            .overlay(alignment: .topLeading) {
                SheetGlassButton(
                    leading: leading, clear: true, escapes: false,
                    accessibilityIdentifier: leading == .close ? "providerOnboardingClose" : "providerOnboardingBack", action: action
                )
                .disabled(!isEnabled)
                .padding(.top, PalMetrics.macPanelCloseTopInset)
                .padding(.leading, PalMetrics.macPanelCloseLeadingInset)
            }
    }
}

struct ProviderColumn<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: LocalEnginePanelMetrics.columnWidth)
            .padding(.horizontal, SetupFooterMetrics.mac.insets.leading)
            .frame(maxWidth: .infinity)
    }
}

struct ProviderScreen<Content: View, Leading: View, Trailing: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            HStack(spacing: SetupFooterMetrics.mac.buttonSpacing) {
                leading
                Spacer(minLength: 0)
                trailing
            }
            .setupFooter(fillsWidth: false)
        }
    }
}

struct ProviderHero: View {
    let providerID: String
    let name: String
    let headline: String
    var detail: String?
    var detailIsProblem = false

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            ProviderLogo.tile(for: providerID, name: name, size: .hero)
            Text(headline)
                .fontWeight(.semibold)
                .hermesText(.sheetTitle)
                .foregroundStyle(PalTokens.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .accessibilityIdentifier("providerHeroHeadline")
            if let detail {
                Text(detail)
                    .hermesText(.botPreview)
                    .foregroundStyle(detailIsProblem ? Color(theme.palette.destructive) : PalTokens.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("providerHeroDetail")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }
}

struct ProviderCaption: View {
    let title: String
    var subtitle: String?
    var identifier: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .fontWeight(.semibold)
                .hermesText(.timestamp)
                .foregroundStyle(PalTokens.textSecondary)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(PalTokens.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 14)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier ?? "providerCaption")
    }
}

struct ProviderNote: View {
    let text: String

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        Text(text)
            .hermesText(.botPreview)
            .foregroundStyle(Color(theme.palette.destructive))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("providerNote")
    }
}

private struct ProviderGlassSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.palClearGlass(RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous), interactive: false)
    }
}

extension View {
    func providerGlass() -> some View {
        modifier(ProviderGlassSurface())
    }
}
#endif
