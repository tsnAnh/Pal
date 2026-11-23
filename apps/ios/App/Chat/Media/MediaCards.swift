import PalChat
import PalDesign
import SwiftUI

extension View {
    func mediaCardFill() -> some View {
        palClearGlass(RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous), interactive: false)
    }
}

struct MediaTooLargeCard: View {
    let media: MediaReference
    let size: Int?
    let compact: Bool
    let transfer: MediaFilePhase
    let download: () -> Void

    var body: some View {
        VStack(spacing: compact ? 4 : 8) {
            PalIcon(media.kind == .audio ? "waveform" : "film", ink: .secondary)
                .font(.system(size: compact ? 17 : 22))
            if !compact {
                Text(media.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(PalTokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(sizeLine)
                .hermesText(.timestamp)
                .foregroundStyle(PalTokens.textSecondary)
                .multilineTextAlignment(.center)
            action
        }
        .padding(compact ? 6 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .mediaCardFill()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatMediaTooLarge")
    }

    private var sizeLine: String {
        guard let size else { return String(localized: "Too large to play here") }
        return String(localized: "\(MediaSize.label(size)) · Too large to play here")
    }

    @ViewBuilder
    private var action: some View {
        switch transfer {
        case .fetching(let fraction):
            ProgressView(value: fraction)
                .controlSize(.small)
                .tint(PalTokens.textPrimary)
                .frame(maxWidth: 140)
                .accessibilityIdentifier("chatMediaDownloading")
        case .failed(let message, _):
            VStack(spacing: 4) {
                Text(message)
                    .hermesText(.timestamp)
                    .foregroundStyle(PalTokens.textSecondary)
                    .multilineTextAlignment(.center)
                downloadButton
            }
        case .idle, .ready:
            downloadButton
        }
    }

    private var downloadButton: some View {
        Button(action: download) {
            if compact {
                Label("Download", palIcon: "arrow.down.to.line").labelStyle(.iconOnly)
            } else {
                Label("Download", palIcon: "arrow.down.to.line")
            }
        }
        .glassButtonStyle()
        .accessibilityLabel(Text("Download \(media.name)"))
        .accessibilityIdentifier("chatMediaDownload")
    }
}

struct MediaFailedCard: View {
    let reason: String
    let retryable: Bool
    let kind: MediaKind
    let retry: () -> Void

    var body: some View {
        Group {
            if retryable {
                Button(action: retry) { content }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chatMediaRetry")
            } else {
                content
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(reason))
        .accessibilityIdentifier("chatMediaFailed")
    }

    private var content: some View {
        VStack(spacing: 4) {
            PalIcon(kind == .audio ? "waveform" : "film", ink: .tertiary)
                .font(.system(size: 17))
            Text(retryable ? "Couldn't load · Retry" : "Couldn't load")
                .hermesText(.timestamp)
                .foregroundStyle(PalTokens.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .mediaCardFill()
    }
}
