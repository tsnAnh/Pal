import PalChat
import PalDesign
import PalProtocol
import SwiftUI

struct ClarifyCard: View {
    let prompt: PendingPrompt
    var accent: BotAccent?
    let answer: (String) -> Void

    @State private var selection: Set<Int> = []
    @State private var otherText = ""
    @FocusState private var otherFocused: Bool

    private var isMulti: Bool { prompt.multiSelect == true }
    private var question: String { prompt.question ?? String(localized: "Question") }
    private var typedAnswer: String? {
        ClarifyAnswer.compose(choices: prompt.choices, selection: [], typed: otherText, multiSelect: false)
    }

    private var composedAnswer: String? {
        if prompt.isBatch {
            return ClarifyAnswer.wire(choices: prompt.choices, selection: selection, typed: otherText, multiSelect: isMulti)
        }
        return ClarifyAnswer.compose(choices: prompt.choices, selection: selection, typed: otherText, multiSelect: isMulti)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ClarifyHeadline(text: question)
            ForEach(Array(prompt.choices.enumerated()), id: \.offset) { index, choice in
                Button { tap(index, choice) } label: {
                    ClarifyRow(letter: ClarifyRow.letter(index), text: choice, style: selection.contains(index) ? .chosen : .choice, accent: accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "\(ClarifyRow.letter(index)), \(choice)"))
                .accessibilityAddTraits(selection.contains(index) ? .isSelected : [])
                .accessibilityIdentifier("clarifyChoice-\(index)")
            }
            ClarifyInputRow(
                letter: ClarifyRow.letter(prompt.choices.count), text: $otherText, focused: $otherFocused,
                hasText: typedAnswer != nil, accent: accent
            ) {
                submitTyped()
            }
            if isMulti, !prompt.choices.isEmpty {
                Button("Confirm and continue") { submitTyped() }
                    .glassButtonStyle()
                    .disabled(composedAnswer == nil)
                    .chatRowFrame(for: .system)
                    .padding(.top, 8)
                    .accessibilityIdentifier("clarifyConfirm")
            }
        }
        .clarifySurface()
        .contextMenu {
            Button { answer("") } label: { Label("Skip question", palIcon: "xmark") }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Skip question")) { answer("") }
        .accessibilityIdentifier("clarifyCard")
    }

    private func submitTyped() {
        guard let composed = composedAnswer else { return }
        answer(composed)
    }

    private func tap(_ index: Int, _ choice: String) {
        if isMulti {
            if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
        } else {
            selection = [index]
            answer(choice)
        }
    }
}

struct ClarifyAnsweredCard: View {
    let question: String
    let answer: ClarifyRecord.Answer
    var accent: BotAccent?

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
                ClarifyRow(letter: nil, text: String(localized: "Skipped"), style: .choice)
            } else {
                ForEach(Array(picks.enumerated()), id: \.offset) { _, pick in
                    ClarifyRow(letter: nil, text: pick, style: .chosen, accent: accent)
                }
            }
        }
        .clarifySurface()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(question), \(spokenAnswer)"))
        .accessibilityIdentifier("clarifyAnswered")
    }
}

struct ClarifyHeadline: View {
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

struct ClarifyRowShell<Content: View>: View {
    let letter: String?
    let style: ClarifyRowStyle
    var accent: BotAccent?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 14) {
            ClarifyBadge(letter: letter, style: style, accent: accent)
            content
        }
        .padding(.vertical, 6)
        .frame(minHeight: ChatMetrics.minimumHitTarget)
        .contentShape(Rectangle())
    }
}

struct ClarifyRow: View {
    let letter: String?
    let text: String
    let style: ClarifyRowStyle
    var accent: BotAccent?

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        ClarifyRowShell(letter: letter, style: style, accent: accent) {
            label
                .font(.body.weight(style == .chosen ? .semibold : .regular))
                .foregroundStyle(Color(style.text(in: theme.palette)))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let recommended = " (Recommended)"

    private var label: Text {
        guard text.hasSuffix(Self.recommended) else { return Text(text) }
        let base = Text(verbatim: String(text.dropLast(Self.recommended.count)))
        let suffix = Text(verbatim: Self.recommended).fontWeight(.regular).foregroundStyle(Color(theme.palette.textTertiary))
        return Text("\(base)\(suffix)")
    }

    static func letter(_ index: Int) -> String {
        String(Character(UnicodeScalar(UInt8(ascii: "A") + UInt8(index % 26))))
    }
}

struct ClarifyBadge: View {
    let letter: String?
    let style: ClarifyRowStyle
    var accent: BotAccent?

    @Environment(\.hermesTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var badgeSide: CGFloat = 26

    var body: some View {
        let fill = style.badgeFill(in: theme.palette, accent: accent)
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Self.color(fill, ink: false) ?? PalTokens.hairline)
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color(theme.palette.cardStroke), lineWidth: fill == nil ? 1 : 0)
            if style == .chosen, letter == nil {
                PalIcon("checkmark", ink: .custom(Self.color(style.badgeText(in: theme.palette, accent: accent), ink: true) ?? .primary))
                    .font(.caption.weight(.bold))
            } else if let letter {
                Text(verbatim: letter)
                    .font(.footnote.weight(.medium))
            }
        }
        .foregroundStyle(Self.color(style.badgeText(in: theme.palette, accent: accent), ink: true) ?? .primary)
        .frame(width: badgeSide, height: badgeSide)
        .accessibilityHidden(true)
    }

    static func color(_ resolved: ClarifyBadgeColor?, ink: Bool) -> Color? {
        switch resolved {
        case .palette(let rgb)?: Color(rgb)
        case .botAccent(let accent)?: ink ? accent.foreground : accent.accent
        case nil: nil
        }
    }
}

struct ClarifyInputRow: View {
    let letter: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let hasText: Bool
    var accent: BotAccent?
    let onSubmit: () -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        let style: ClarifyRowStyle = hasText || focused.wrappedValue ? .chosen : .choice
        let placeholder = String(localized: "Something else")
        ClarifyRowShell(letter: letter, style: style, accent: accent) {
            TextField(
                "",
                text: $text,
                prompt: Text(placeholder).foregroundStyle(Color(style.placeholder(in: theme.palette)))
            )
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .font(.body)
            .foregroundStyle(Color(style.typedText(in: theme.palette)))
            .focused(focused)
            .submitLabel(.send)
            .onSubmit(onSubmit)
            .accessibilityLabel(Text(verbatim: placeholder))
            .accessibilityIdentifier("clarifyOtherField")
        }
        .onTapGesture { focused.wrappedValue = true }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(style == .chosen ? .isSelected : [])
        .accessibilityIdentifier("clarifyOther")
    }
}

extension View {
    func clarifySurface() -> some View {
        modifier(ClarifySurface())
    }
}

private struct ClarifySurface: ViewModifier {
    @Environment(\.hermesTheme) private var theme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: ChatMetrics.bubbleRadius, style: .continuous)
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(theme.palette.groupedCard), in: shape)
            .overlay(shape.strokeBorder(Color(theme.palette.cardStroke), lineWidth: 1))
    }
}
