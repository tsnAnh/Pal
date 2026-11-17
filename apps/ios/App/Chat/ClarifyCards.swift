import PalChat
import PalDesign
import PalProtocol
import SwiftUI

struct ClarifyCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let prompt: PendingPrompt
    let answer: (String) -> Void

    @State private var selection: Set<Int> = []
    @State private var typingOther = false
    @State private var otherText = ""
    @FocusState private var otherFocused: Bool

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
            Button { openOther() } label: {
                ClarifyRow(letter: ClarifyRow.letter(prompt.choices.count), text: String(localized: "Something else"), style: typingOther ? .chosen : .freeText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "\(ClarifyRow.letter(prompt.choices.count)), \(String(localized: "Something else"))"))
            .accessibilityHint(Text("Type your own answer"))
            .accessibilityAddTraits(typingOther ? .isSelected : [])
            .accessibilityIdentifier("clarifyOther")
            if typingOther {
                otherField
            }
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

    private var trimmedOther: String { otherText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var otherField: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField("Type your answer", text: $otherText)
                .textFieldStyle(.roundedBorder)
                .focused($otherFocused)
                .submitLabel(.send)
                .onSubmit { sendOther() }
                .onAppear { otherFocused = true }
                .accessibilityIdentifier("clarifyOtherField")
            HStack(spacing: 12) {
                Button("Cancel") { closeOther() }
                    .accessibilityIdentifier("clarifyOtherCancel")
                Button("Send") { sendOther() }
                    .buttonStyle(.glass(PalGlass.style(interactive: false, colorScheme: colorScheme)))
                    .disabled(trimmedOther.isEmpty)
                    .accessibilityIdentifier("clarifyOtherSend")
            }
        }
        .padding(.top, 4)
    }

    private func openOther() {
        typingOther = true
    }

    private func closeOther() {
        typingOther = false
        otherFocused = false
    }

    private func sendOther() {
        let text = trimmedOther
        guard !text.isEmpty else { return }
        answer(text)
    }

    private func tap(_ index: Int, _ choice: String) {
        closeOther()
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
