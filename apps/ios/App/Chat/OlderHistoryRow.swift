import PalDesign
import SwiftUI

struct OlderHistoryRow: View {
    let state: OlderHistory
    let ink: Color
    let retry: () -> Void

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
            caption(Text("Loading earlier messages"))
        case .failed:
            Button(action: retry) {
                HStack(spacing: 0) {
                    caption(Text("Couldn't load earlier messages · "))
                    Text("Retry")
                        .hermesText(.timestamp)
                        .foregroundStyle(ink)
                }
                .frame(minHeight: ChatMetrics.minimumHitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Couldn't load earlier messages. Retry"))
            .accessibilityIdentifier("olderHistoryRetry")
        case .complete:
            caption(Text("Start of your chat"))
        }
    }

    private func caption(_ text: Text) -> some View {
        text
            .hermesText(.timestamp)
            .foregroundStyle(PalTokens.textTertiary)
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
