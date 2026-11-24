import PalChat
import PalDesign
import PalProtocol
import SwiftUI

private extension View {
    func chatCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PalTokens.agentBubble, in: RoundedRectangle(cornerRadius: ChatMetrics.bubbleRadius, style: .continuous))
    }
}

struct NoProviderCard: View {
    let connect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pal needs an AI model to reply")
                    .font(.headline)
                    .foregroundStyle(PalTokens.textPrimary)
                Text("Connect a provider and send your message again.")
                    .hermesText(.chatBody)
                    .foregroundStyle(PalTokens.textPrimary)
            }
            Button("Connect a model", action: connect)
                .glassButtonStyle(prominent: true)
                .accessibilityIdentifier("noProviderConnect")
        }
        .chatCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("noProviderCard")
    }
}

struct ConnectionRequestCard: View {
    @Environment(\.hermesTheme) private var theme

    let card: ConnectionCard
    let answering: Set<String>
    let decide: (ConnectionTarget, ConnectionDecision) -> Void

    @State private var now = Date()

    static func answerKey(opID: String, target: String) -> String { "\(opID)/\(target)" }

    private enum Phase: String {
        case open
        case settled
        case lapsed
    }

    private var phase: Phase {
        if card.operation.settled { return .settled }
        return card.isOpen(now: now) ? .open : .lapsed
    }

    private var closingNote: String? {
        let operation = card.operation
        let resolved = operation.targets.contains { $0.state == .connected || $0.state == .skipped || $0.state == .declined }
        switch phase {
        case .open: return nil
        case .settled: return operation.settledBy == .deadline && !resolved ? String(localized: "This request timed out") : nil
        case .lapsed:
            if card.lapsed { return String(localized: "This request has ended") }
            return String(localized: "This request timed out")
        }
    }

    private func stateLine(for target: ConnectionTarget) -> String? {
        switch target.state {
        case .initiated: String(localized: "Turning on…")
        case .connected: Self.connectedLine(toolCount: target.tools.count)
        case .declined: String(localized: "Not installed")
        case .skipped: String(localized: "Skipped")
        case .failed: String(localized: "Couldn't turn on")
        case .notConnected: String(localized: "Not turned on")
        case .expired: String(localized: "Timed out")
        case .pending, .unknown: nil
        }
    }

    private static func connectedLine(toolCount: Int) -> String {
        switch toolCount {
        case 0: String(localized: "On")
        case 1: String(localized: "On · 1 tool ready")
        default: String(localized: "On · \(toolCount) tools ready")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let note = closingNote {
                Text(note)
                    .font(.body)
                    .foregroundStyle(Color(theme.palette.textPrimary))
            }
            ForEach(card.operation.targets) { target in
                targetRow(target)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(theme.palette.groupedCard), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectionCard")
        .accessibilityValue(phase.rawValue)
        .task(id: card.operation.deadlineAt) {
            let remaining = card.operation.deadlineAt.timeIntervalSinceNow
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            now = Date()
        }
    }

    private func targetRow(_ target: ConnectionTarget) -> some View {
        let decisions = card.decisions(for: target, now: now)
        let busy = answering.contains(Self.answerKey(opID: card.operation.opID, target: target.name))
        return VStack(alignment: .leading, spacing: 8) {
            Text(target.name)
                .font(.body)
                .foregroundStyle(Color(theme.palette.textPrimary))
                .accessibilityIdentifier("connectionState-\(target.name)")
                .accessibilityValue(target.state.rawValue)
            if let line = stateLine(for: target) {
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(Color(theme.palette.textSecondary))
            }
            if target.detail != nil || target.discoveryError != nil {
                DisclosureGroup("Details") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach([target.detail, target.discoveryError].compactMap { $0 }, id: \.self) { text in
                            Text(text)
                                .font(.footnote)
                                .foregroundStyle(Color(theme.palette.textSecondary))
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                .font(.subheadline)
                .foregroundStyle(Color(theme.palette.textSecondary))
                .tint(Color(theme.palette.textSecondary))
                .accessibilityIdentifier("connectionDetails-\(target.name)")
            }
            if decisions.contains(.tryAgain) {
                Button(String(localized: "Try again")) { decide(target, .tryAgain) }
                    .glassButtonStyle()
                    .disabled(busy)
                    .accessibilityIdentifier("connectionRetry-\(target.name)")
            }
        }
    }
}
