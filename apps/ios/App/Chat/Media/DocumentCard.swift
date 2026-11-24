import PalChat
import PalDesign
import SwiftUI

struct DocumentCard: View {
    let strip: DocumentStrip
    let state: MediaPreviewState
    let thumbnail: CGImage?
    let transfer: MediaFilePhase
    let open: () -> Void
    let download: () -> Void
    let retry: () -> Void

    private static let width = DocumentCardMetrics.width
    private static let thumbnailHeight = DocumentCardMetrics.thumbnailHeight

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous)
    }

    var body: some View {
        if case .ready = state {
            Button(action: open) { card }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(strip.accessibilityLabel))
                .accessibilityHint(Text(DocumentStrip.openHint))
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("chatDocumentOpen")
        } else {
            card
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            thumbnailArea
                .frame(width: Self.width, height: Self.thumbnailHeight)
                .clipped()
            stripView
        }
        .frame(width: Self.width, alignment: .leading)
        .mediaCardFill()
        .clipShape(shape)
        .shadow(color: PalTokens.scrim.opacity(0.22), radius: 6, y: 2)
        .contentShape(shape)
        .accessibilityIdentifier("chatDocumentCard")
    }

    @ViewBuilder
    private var thumbnailArea: some View {
        switch state {
        case .idle, .loading:
            ZStack {
                PalTokens.agentBubble
                DelayedProgressView(after: ChatLoading.delay).controlSize(.small).tint(PalTokens.textTertiary)
            }
            .accessibilityIdentifier("chatDocumentLoading")
        case .ready:
            readyThumbnail
        case .tooLarge(let size):
            tooLarge(size)
        case .failed(let reason, let retryable):
            failed(reason, retryable: retryable)
        }
    }

    @ViewBuilder
    private var readyThumbnail: some View {
        if let thumbnail {
            Image(platformImage: PlatformImage(cgImage: thumbnail))
                .resizable()
                .scaledToFill()
                .frame(width: Self.width, height: Self.thumbnailHeight, alignment: .top)
                .clipped()
        } else {
            ZStack {
                PalTokens.agentBubble
                PalIcon(strip.kind.iconName, ink: .tertiary).font(.system(size: 28))
            }
        }
    }

    private var stripView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(strip.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(PalTokens.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(strip.detail)
                .hermesText(.timestamp)
                .foregroundStyle(PalTokens.textSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityIdentifier("chatDocumentStrip")
    }

    private func tooLarge(_ size: Int?) -> some View {
        VStack(spacing: 8) {
            PalIcon(strip.kind.iconName, ink: .secondary).font(.system(size: 22))
            Text(tooLargeLine(size))
                .hermesText(.timestamp)
                .foregroundStyle(PalTokens.textSecondary)
                .multilineTextAlignment(.center)
            transferAction
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatDocumentTooLarge")
    }

    private func tooLargeLine(_ size: Int?) -> String {
        guard let size else { return String(localized: "Too large to preview") }
        return String(localized: "\(MediaSize.label(size)) · Too large to preview")
    }

    @ViewBuilder
    private var transferAction: some View {
        switch transfer {
        case .fetching(let fraction):
            ProgressView(value: fraction)
                .controlSize(.small)
                .tint(PalTokens.textPrimary)
                .frame(maxWidth: 140)
                .accessibilityIdentifier("chatDocumentDownloading")
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
            Label("Download", palIcon: "arrow.down.to.line")
        }
        .glassButtonStyle()
        .accessibilityLabel(Text("Download \(strip.name)"))
        .accessibilityIdentifier("chatDocumentDownload")
    }

    private func failed(_ reason: String, retryable: Bool) -> some View {
        VStack(spacing: 8) {
            PalIcon(strip.kind.iconName, ink: .tertiary).font(.system(size: 22))
            Text(reason)
                .hermesText(.timestamp)
                .foregroundStyle(PalTokens.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            if retryable {
                Button(action: retry) {
                    Label("Retry", palIcon: "arrow.clockwise")
                }
                .glassButtonStyle()
                .accessibilityIdentifier("chatDocumentRetry")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatDocumentFailed")
    }
}
