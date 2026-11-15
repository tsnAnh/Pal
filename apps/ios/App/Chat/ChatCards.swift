import PalChat
import PalDesign
import PalProtocol
import SwiftUI

struct ClarifyCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let prompt: PendingPrompt
    let answer: (String) -> Void

    @State private var selection: Set<Int> = []

    @Environment(\.hermesTheme) private var theme

    private var isMulti: Bool { prompt.multiSelect == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Text(prompt.question ?? String(localized: "Question"))
                    .font(.headline)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { answer("") } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color(theme.palette.textSecondary))
                        .frame(width: 32, height: 32)
                        .minimumHitTarget(visual: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Skip question"))
                .accessibilityIdentifier("clarifySkip")
            }
            ForEach(Array(prompt.choices.enumerated()), id: \.offset) { index, choice in
                Button { tap(index, choice) } label: {
                    HStack(spacing: 14) {
                        Text(Self.letter(index))
                            .font(.footnote)
                            .foregroundStyle(Color(selection.contains(index) ? theme.palette.chipSelectedText : theme.palette.textSecondary))
                            .frame(width: 30, height: 30)
                            .background(
                                Color(selection.contains(index) ? theme.palette.chipSelectedFill : theme.palette.circleButtonFill),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                        Text(choice)
                            .font(.body)
                            .foregroundStyle(Color(theme.palette.textPrimary))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(choice))
                .accessibilityAddTraits(selection.contains(index) ? .isSelected : [])
                .accessibilityIdentifier("clarifyChoice-\(index)")
            }
            if isMulti, !prompt.choices.isEmpty {
                Button("Confirm and continue") { confirm() }
                    .buttonStyle(.glass(PalGlass.style(interactive: false, colorScheme: colorScheme)))
                    .disabled(selection.isEmpty)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("clarifyConfirm")
            }
        }
        .chatCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clarifyCard")
    }

    private func tap(_ index: Int, _ choice: String) {
        if isMulti {
            if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
        } else {
            answer(choice)
        }
    }

    private func confirm() {
        answer(selection.sorted().map { String($0 + 1) }.joined(separator: ","))
    }

    private static func letter(_ index: Int) -> String {
        String(Character(UnicodeScalar(UInt8(ascii: "A") + UInt8(index % 26))))
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
        VStack(alignment: .leading, spacing: 16) {
            Text(question)
                .font(.headline)
                .foregroundStyle(Color(theme.palette.textPrimary))
                .frame(maxWidth: .infinity, alignment: .leading)
            if picks.isEmpty {
                Text("Skipped")
                    .font(.body)
                    .foregroundStyle(Color(theme.palette.textSecondary))
            } else {
                ForEach(Array(picks.enumerated()), id: \.offset) { _, pick in
                    HStack(spacing: 14) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color(theme.palette.chipSelectedText))
                            .frame(width: 30, height: 30)
                            .background(Color(theme.palette.chipSelectedFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text(pick)
                            .font(.body)
                            .foregroundStyle(Color(theme.palette.textPrimary))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .chatCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(question), \(spokenAnswer)"))
        .accessibilityIdentifier("clarifyAnswered")
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
