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
        MediaTooLargePanel(
            icon: media.kind == .audio ? "waveform" : "film", name: media.name,
            line: MediaStateText.tooLarge(size: size, playable: true), transfer: transfer, idPrefix: "chatMedia",
            compact: compact, download: download
        )
        .mediaCardFill()
        .accessibilityLabel(Text(MediaAccessibility.tooLarge(kind: media.kind == .audio ? "Audio" : "Video", name: media.name, size: size)))
    }
}

struct MediaFailedCard: View {
    let media: MediaReference
    let reason: String
    let retryable: Bool
    var compact = false
    let retry: () -> Void

    var body: some View {
        MediaFailedPanel(
            icon: media.kind == .audio ? "waveform" : "film", reason: reason, retryable: retryable, idPrefix: "chatMedia",
            compact: compact, retry: retry
        )
        .mediaCardFill()
        .accessibilityLabel(Text(MediaAccessibility.failed(kind: media.kind == .audio ? "Audio" : "Video", name: media.name, reason: reason)))
    }
}
