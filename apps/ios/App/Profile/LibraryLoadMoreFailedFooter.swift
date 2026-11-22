import PalDesign
import SwiftUI

struct LibraryLoadMoreFailedFooter: View {
    let showsChrome: Bool
    let retry: () -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            message
            Button(String(localized: "Try again"), action: retry)
                .buttonStyle(.glass)
                .accessibilityIdentifier("libraryLoadMoreRetry")
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("libraryLoadMoreFailed")
    }

    @ViewBuilder
    private var message: some View {
        let text = Text(String(localized: "Couldn't load more"))
        if showsChrome {
            text.hermesText(.rowSubtitle).foregroundStyle(Color(theme.palette.textSecondary))
        } else {
            text.font(.system(size: 12)).foregroundStyle(PalTokens.textSecondary)
        }
    }
}
