import PalChat
import PalDesign
import SwiftUI

struct MediaTooLargePanel: View {
    let icon: String
    let name: String
    let line: String
    let transfer: MediaFilePhase
    let idPrefix: String
    var compact = false
    let download: () -> Void

    @ScaledMetric(relativeTo: .body) private var iconSize = 22
    @ScaledMetric(relativeTo: .caption) private var compactIconSize = 17

    var body: some View {
        VStack(spacing: compact ? 4 : 8) {
            PalIcon(icon, ink: .secondary)
                .font(.system(size: compact ? compactIconSize : iconSize))
            if !compact {
                Text(name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(PalTokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(line)
                .hermesText(.timestamp)
                .foregroundStyle(PalTokens.textSecondary)
                .multilineTextAlignment(.center)
            action
        }
        .padding(compact ? 6 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(idPrefix)TooLarge")
    }

    @ViewBuilder
    private var action: some View {
        switch transfer {
        case .fetching(let fraction):
            ProgressView(value: fraction)
                .controlSize(.small)
                .tint(PalTokens.textPrimary)
                .frame(maxWidth: 140)
                .accessibilityLabel(Text("Downloading \(name)"))
                .accessibilityIdentifier("\(idPrefix)Downloading")
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
        .accessibilityLabel(Text("Download \(name)"))
        .accessibilityIdentifier("\(idPrefix)Download")
    }
}

struct MediaFailedPanel: View {
    let icon: String
    let reason: String
    let retryable: Bool
    let idPrefix: String
    var compact = false
    let retry: () -> Void

    @ScaledMetric(relativeTo: .body) private var iconSize = 22
    @ScaledMetric(relativeTo: .caption) private var compactIconSize = 17

    var body: some View {
        VStack(spacing: compact ? 4 : 8) {
            PalIcon(icon, ink: .tertiary)
                .font(.system(size: compact ? compactIconSize : iconSize))
            Text(reason)
                .hermesText(.timestamp)
                .foregroundStyle(PalTokens.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(compact ? 2 : 3)
            if retryable {
                Button(action: retry) {
                    if compact {
                        Label("Retry", palIcon: "arrow.clockwise").labelStyle(.iconOnly)
                    } else {
                        Label("Retry", palIcon: "arrow.clockwise")
                    }
                }
                .glassButtonStyle()
                .accessibilityLabel(Text("Retry"))
                .accessibilityIdentifier("\(idPrefix)Retry")
            }
        }
        .padding(compact ? 6 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(idPrefix)Failed")
    }
}
