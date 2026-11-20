import PalConnect
import PalDesign
import SwiftUI

struct ConnectConnectedMark: View {
    var body: some View {
        HStack(spacing: 5) {
            PalIcon("checkmark", ink: .secondary)
                .font(.system(size: 12, weight: .semibold))
            Text("Connected")
        }
        .font(.system(size: ConnectRowMetrics.subtitleSize))
        .foregroundStyle(PalTokens.textSecondary)
        .lineLimit(1)
        .fixedSize()
    }
}

struct ConnectCapsule: View {
    let state: ConnectRowState
    let identifier: String
    var quiet = false
    let perform: () -> Void

    private var capsuleStyle: PalClearCapsuleStyle {
        #if os(macOS)
        PalClearCapsuleStyle()
        #else
        PalClearCapsuleStyle(height: 30, horizontalPadding: 14)
        #endif
    }

    var body: some View {
        switch state {
        case .connect, .setUp, .needsAttention, .connected:
            if quiet, state == .connected {
                Button(action: perform) { ConnectConnectedMark() }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: state.actionTitle ?? ""))
                    .accessibilityIdentifier(identifier)
            } else {
                Button(action: perform) { Text(verbatim: state.actionTitle ?? "") }
                    .buttonStyle(capsuleStyle)
                    .opacity(state == .connected ? 0.7 : 1)
                    .accessibilityIdentifier(identifier)
            }
        case .waiting:
            if quiet {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Connecting")
                }
                .font(.system(size: ConnectRowMetrics.subtitleSize))
                .foregroundStyle(PalTokens.textSecondary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(identifier)
            } else {
                Button {} label: {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Connecting")
                    }
                }
                .buttonStyle(capsuleStyle)
                .disabled(true)
                .accessibilityIdentifier(identifier)
            }
        case .unavailable:
            EmptyView()
        }
    }
}
