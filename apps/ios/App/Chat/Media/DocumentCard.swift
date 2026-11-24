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

    @ScaledMetric(relativeTo: .title) private var glyphSize = 28

    private var areaHeight: CGFloat {
        strip.kind.hasThumbnail ? DocumentCardMetrics.thumbnailHeight : DocumentCardMetrics.iconHeight
    }

    private var showsImage: Bool {
        if case .ready = state { return thumbnail != nil }
        return false
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous)
    }

    var body: some View {
        if case .ready = state {
            Button(action: open) { card }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(strip.accessibilityLabel))
                .accessibilityHint(Text(MediaAccessibility.openHint))
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("chatDocumentOpen")
        } else {
            card
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(stateLabel))
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            thumbnailArea
                .frame(width: Self.width, height: showsImage ? areaHeight : nil)
                .frame(minHeight: areaHeight)
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
                .frame(width: Self.width, height: areaHeight, alignment: .top)
                .clipped()
        } else {
            ZStack {
                PalTokens.agentBubble
                PalIcon(strip.kind.iconName, ink: .tertiary).font(.system(size: glyphSize))
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
        MediaTooLargePanel(
            icon: strip.kind.iconName, name: strip.name, line: MediaStateText.tooLarge(size: size, playable: false),
            transfer: transfer, idPrefix: "chatDocument", download: download
        )
    }

    private func failed(_ reason: String, retryable: Bool) -> some View {
        MediaFailedPanel(icon: strip.kind.iconName, reason: reason, retryable: retryable, idPrefix: "chatDocument", retry: retry)
    }

    private var stateLabel: String {
        switch state {
        case .tooLarge(let size): MediaAccessibility.tooLarge(kind: strip.kind.spokenName, name: strip.name, size: size)
        case .failed(let reason, _): MediaAccessibility.failed(kind: strip.kind.spokenName, name: strip.name, reason: reason)
        case .idle, .loading, .ready: strip.accessibilityLabel
        }
    }
}
