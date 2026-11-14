import PalDesign
import SwiftUI

struct OlderHistoryRow: View {
    let state: OlderHistory
    let retry: () -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .accessibilityIdentifier("olderHistoryRow")
            .accessibilityValue(Text(accessibilityValue))
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            Color.clear
        case .loading:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(Text("Loading earlier messages"))
        case .failed:
            Button(action: retry) {
                Text("Couldn't load earlier messages. Tap to try again.")
                    .hermesText(.chatStatus)
                    .foregroundStyle(Color(theme.palette.textSecondary))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("olderHistoryRetry")
        case .complete:
            Text("Start of your chat")
                .hermesText(.chatStatus)
                .foregroundStyle(Color(theme.palette.textSecondary))
        }
    }

    private var accessibilityValue: String {
        switch state {
        case .idle: "idle"
        case .loading: "loading"
        case .failed: "failed"
        case .complete: "start"
        }
    }

    private static let height: CGFloat = 44
}
