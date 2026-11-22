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
                    .buttonStyle(.glass)
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
                .buttonStyle(.glass)
                .disabled(true)
                .accessibilityIdentifier(identifier)
            }
        case .unavailable:
            EmptyView()
        }
    }
}

struct ConnectOpenMark: View {
    let state: ConnectRowState

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            if case .needsAttention = state {
                Text("Needs sign-in")
                    .font(.system(size: ConnectRowMetrics.subtitleSize))
                    .foregroundStyle(Color(theme.palette.destructive))
                    .lineLimit(1)
                    .fixedSize()
            } else {
                ConnectConnectedMark()
            }
            PalIcon("chevron.right", ink: .tertiary)
                .font(.system(size: 12, weight: .semibold))
                .accessibilityHidden(true)
        }
    }
}

extension ConnectRowState {
    var showsOpenMark: Bool {
        switch self {
        case .connected, .needsAttention: true
        default: false
        }
    }
}
