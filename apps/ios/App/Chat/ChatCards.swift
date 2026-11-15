import PalChat
import PalDesign
import PalProtocol
import SwiftUI

struct ClarifyCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.focusComposer) private var focusComposer
    let prompt: PendingPrompt
    let answer: (String) -> Void

    @State private var selection: Set<Int> = []

    private var isMulti: Bool { prompt.multiSelect == true }
    private var question: String { prompt.question ?? String(localized: "Question") }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ClarifyHeadline(text: question)
            ForEach(Array(prompt.choices.enumerated()), id: \.offset) { index, choice in
                Button { tap(index, choice) } label: {
                    ClarifyRow(letter: ClarifyRow.letter(index), text: choice, style: selection.contains(index) ? .chosen : .choice)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "\(ClarifyRow.letter(index)), \(choice)"))
                .accessibilityAddTraits(selection.contains(index) ? .isSelected : [])
                .accessibilityIdentifier("clarifyChoice-\(index)")
            }
            Button { focusComposer?() } label: {
                ClarifyRow(letter: ClarifyRow.letter(prompt.choices.count), text: String(localized: "Something else"), style: .freeText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "\(ClarifyRow.letter(prompt.choices.count)), \(String(localized: "Something else"))"))
            .accessibilityHint(Text("Type your own answer"))
            .accessibilityIdentifier("clarifyOther")
            if isMulti, !prompt.choices.isEmpty {
                Button("Confirm and continue") { confirm() }
                    .buttonStyle(.glass(PalGlass.style(interactive: false, colorScheme: colorScheme)))
                    .disabled(selection.isEmpty)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .accessibilityIdentifier("clarifyConfirm")
            }
        }
        .clarifySurface()
        .contextMenu {
            Button("Skip question", systemImage: "xmark") { answer("") }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Skip question")) { answer("") }
        .accessibilityIdentifier("clarifyCard")
    }

    private func tap(_ index: Int, _ choice: String) {
        if isMulti {
            if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
        } else {
            selection = [index]
            answer(choice)
        }
    }

    private func confirm() {
        answer(selection.sorted().map { String($0 + 1) }.joined(separator: ","))
    }
}

struct ClarifyAnsweredCard: View {
    let question: String
    let answer: ClarifyRecord.Answer

    @Environment(\.hermesTheme) private var theme

    private var picks: [String] {
        if case .answered(let picks) = answer { picks } else { [] }
    }

    private var spokenAnswer: String {
        picks.isEmpty ? String(localized: "Skipped") : picks.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ClarifyHeadline(text: question)
            if picks.isEmpty {
                ClarifyRow(letter: nil, text: String(localized: "Skipped"), style: .freeText)
            } else {
                ForEach(Array(picks.enumerated()), id: \.offset) { _, pick in
                    ClarifyRow(letter: nil, text: pick, style: .chosen)
                }
            }
        }
        .clarifySurface()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(question), \(spokenAnswer)"))
        .accessibilityIdentifier("clarifyAnswered")
    }
}

private struct ClarifyHeadline: View {
    let text: String

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(Color(theme.palette.textPrimary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct ClarifyRow: View {
    enum Style { case choice, chosen, freeText }

    let letter: String?
    let text: String
    let style: Style

    @Environment(\.hermesTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var badgeSide: CGFloat = 26

    var body: some View {
        HStack(spacing: 14) {
            badge
            Text(text)
                .font(.body)
                .foregroundStyle(Color(style == .freeText ? theme.palette.textSecondary : theme.palette.textPrimary))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .frame(minHeight: ChatMetrics.minimumHitTarget)
        .contentShape(Rectangle())
    }

    private var badge: some View {
        let chosen = style == .chosen
        return ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(chosen ? Color(theme.palette.chipSelectedFill) : PalTokens.hairline)
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color(theme.palette.cardStroke), lineWidth: chosen ? 0 : 1)
            if chosen, letter == nil {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
            } else if let letter {
                Text(verbatim: letter)
                    .font(.footnote.weight(.medium))
            }
        }
        .foregroundStyle(Color(chosen ? theme.palette.chipSelectedText : theme.palette.textSecondary))
        .frame(width: badgeSide, height: badgeSide)
        .accessibilityHidden(true)
    }

    static func letter(_ index: Int) -> String {
        String(Character(UnicodeScalar(UInt8(ascii: "A") + UInt8(index % 26))))
    }
}

private extension View {
    func clarifySurface() -> some View {
        modifier(ClarifySurface())
    }
}

private struct ClarifySurface: ViewModifier {
    @Environment(\.hermesTheme) private var theme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: ChatMetrics.bubbleRadius, style: .continuous)
        content
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(theme.palette.groupedCard), in: shape)
            .overlay(shape.strokeBorder(Color(theme.palette.cardStroke), lineWidth: 1))
    }
}

struct ApprovalCard: View {
    let prompt: PendingPrompt
    let ink: Color
    let inkText: Color
    let choose: (String) -> Void

    @State private var showsMore = false

    private var primary: String? {
        prompt.choices.contains("once") ? "once" : prompt.choices.first { $0 != "deny" }
    }

    private var scoped: [String] {
        prompt.choices.filter { $0 != primary && $0 != "deny" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Needs your OK")
                    .font(.headline)
                    .foregroundStyle(PalTokens.textPrimary)
                Text("This could change or delete something. Allow it?")
                    .hermesText(.chatBody)
                    .foregroundStyle(PalTokens.textPrimary)
            }
            details
            HStack(spacing: 8) {
                if let primary {
                    choiceButton(primary) {
                        Text(ApprovalWording.label(for: primary))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(inkText)
                            .padding(.horizontal, 20)
                            .frame(minHeight: ChatMetrics.minimumHitTarget)
                            .background(ink, in: Capsule())
                    }
                }
                if prompt.choices.contains("deny") {
                    choiceButton("deny") {
                        Text(ApprovalWording.label(for: "deny"))
                            .font(.body)
                            .foregroundStyle(PalTokens.textPrimary)
                            .padding(.horizontal, 12)
                            .frame(minHeight: ChatMetrics.minimumHitTarget)
                    }
                }
            }
            if !scoped.isEmpty {
                DisclosureGroup(isExpanded: $showsMore) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(scoped, id: \.self) { choice in
                            choiceButton(choice) {
                                Text(ApprovalWording.label(for: choice))
                                    .font(.body)
                                    .foregroundStyle(PalTokens.textPrimary)
                                    .frame(maxWidth: .infinity, minHeight: ChatMetrics.minimumHitTarget, alignment: .leading)
                            }
                        }
                    }
                } label: {
                    Text("More options")
                        .font(.subheadline)
                        .foregroundStyle(PalTokens.textSecondary)
                }
                .tint(PalTokens.textSecondary)
                .accessibilityIdentifier("approvalMoreOptions")
            }
        }
        .chatCard()
    }

    @ViewBuilder
    private var details: some View {
        if prompt.description != nil || prompt.command != nil {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    if let description = prompt.description {
                        Text(description)
                            .hermesText(.chatStatus)
                            .foregroundStyle(PalTokens.textSecondary)
                    }
                    if let command = prompt.command {
                        Text(command)
                            .hermesText(.chatCode)
                            .monospaced()
                            .foregroundStyle(PalTokens.textSecondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            } label: {
                Text("Details")
                    .font(.subheadline)
                    .foregroundStyle(PalTokens.textSecondary)
            }
            .tint(PalTokens.textSecondary)
            .accessibilityIdentifier("approvalDetails")
        }
    }

    private func choiceButton(_ choice: String, @ViewBuilder label: () -> some View) -> some View {
        let index = prompt.choices.firstIndex(of: choice) ?? 0
        return Button { choose(choice) } label: { label().contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .accessibilityIdentifier("approvalChoice-\(index)")
    }
}

struct ApprovalAnsweredCard: View {
    let record: ApprovalRecord

    private var outcome: String {
        guard let decision = record.decision else { return String(localized: "Answered") }
        return ApprovalWording.label(for: decision.rawValue)
    }

    private var symbol: String {
        record.decision == .deny ? "xmark" : "checkmark"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Needs your OK")
                .font(.headline)
                .foregroundStyle(PalTokens.textPrimary)
            if !record.request.isEmpty {
                Text(record.request)
                    .hermesText(.chatBody)
                    .foregroundStyle(PalTokens.textSecondary)
                    .lineLimit(3)
            }
            Label(outcome, systemImage: symbol)
                .hermesText(.chatBody)
                .foregroundStyle(PalTokens.textPrimary)
        }
        .chatCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Needs your OK, \(outcome)"))
        .accessibilityIdentifier("approvalAnswered")
    }
}

enum ApprovalWording {
    static func label(for choice: String) -> String {
        switch choice {
        case "once": String(localized: "Allow")
        case "session": String(localized: "Allow for this chat")
        case "always": String(localized: "Always allow")
        case "deny": String(localized: "Don't allow")
        default: choice
        }
    }
}

private extension View {
    func chatCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PalTokens.agentBubble, in: RoundedRectangle(cornerRadius: ChatMetrics.bubbleRadius, style: .continuous))
    }
}

extension DeviceMcpServer {
    var displayName: String {
        switch self {
        case .t3code: String(localized: "T3 Code")
        }
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

    private var isActionable: Bool { card.isActionable(now: now) }

    private var closingNote: String? {
        let operation = card.operation
        let resolved = operation.targets.contains { $0.state == .connected || $0.state == .skipped }
        switch phase {
        case .open: return nil
        case .settled: return operation.settledBy == .deadline && !resolved ? String(localized: "This request timed out") : nil
        case .lapsed:
            if card.lapsed { return String(localized: "This request has ended") }
            return String(localized: "This request timed out")
        }
    }

    private static func name(of target: ConnectionTarget) -> String {
        DeviceMcpServer(rawValue: target.name)?.displayName ?? target.name
    }

    private func prompt(for target: ConnectionTarget) -> String {
        let name = Self.name(of: target)
        return target.action == "enable" ? String(localized: "Let this bot use \(name)?") : String(localized: "Set up \(name)?")
    }

    private func stateLine(for target: ConnectionTarget) -> String? {
        switch target.state {
        case .initiated: String(localized: "Turning on…")
        case .connected: Self.connectedLine(toolCount: target.tools.count)
        case .skipped: String(localized: "Not allowed")
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

    private static func label(for decision: ConnectionDecision) -> String {
        switch decision {
        case .allow: String(localized: "Allow")
        case .deny: String(localized: "Don't allow")
        case .tryAgain: String(localized: "Try again")
        }
    }

    private static func identifier(for decision: ConnectionDecision, target: String) -> String {
        switch decision {
        case .allow: "connectionAllow-\(target)"
        case .deny: "connectionDeny-\(target)"
        case .tryAgain: "connectionRetry-\(target)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isActionable {
                Text("Needs your OK")
                    .font(.headline)
                    .foregroundStyle(Color(theme.palette.textPrimary))
            }
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
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color(theme.palette.cardStroke), lineWidth: 1))
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
            Text(decisions.contains(.allow) || decisions.contains(.deny) ? prompt(for: target) : Self.name(of: target))
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
            ForEach(decisions, id: \.self) { decision in
                Button(Self.label(for: decision)) { decide(target, decision) }
                    .buttonStyle(.glass)
                    .disabled(busy)
                    .accessibilityIdentifier(Self.identifier(for: decision, target: target.name))
            }
        }
    }
}
