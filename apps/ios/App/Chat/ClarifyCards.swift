import PalChat
import PalDesign
import PalProtocol
import SwiftUI

struct ClarifyCard: View {
    let prompt: PendingPrompt
    var accent: BotAccent?
    let answer: (String, ClarifySettled) async -> Bool

    @State private var selection: Set<Int> = []
    @State private var otherText = ""
    @State private var sending = false
    @State private var settled: ClarifySettled?
    @FocusState private var otherFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        ZStack(alignment: .top) {
            if let settled {
                ClarifySettledCard(settled: settled).transition(PalMotion.Settle.fade)
            } else {
                live.transition(PalMotion.Settle.fade)
            }
        }
        .animation(PalMotion.Settle.height(reduceMotion: reduceMotion), value: settled)
    }

    private var live: some View {
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
            Button { send("", chosen: []) } label: { Label("Skip question", palIcon: "xmark") }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Skip question")) { send("", chosen: []) }
        .accessibilityIdentifier("clarifyCard")
    }

    private func submitTyped() {
        guard let composed = composedAnswer else { return }
        let typed = otherText.trimmingCharacters(in: .whitespacesAndNewlines)
        let picked = selection.sorted().compactMap { prompt.choices.indices.contains($0) ? prompt.choices[$0] : nil }
        send(composed, chosen: isMulti ? picked + (typed.isEmpty ? [] : [typed]) : [typed])
    }

    private func tap(_ index: Int, _ choice: String) {
        if isMulti {
            if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
        } else {
            selection = [index]
            send(choice, chosen: [choice])
        }
    }

    private func send(_ text: String, chosen: [String]) {
        guard !sending else { return }
        sending = true
        let record = ClarifySettled(entries: [.init(question: question, chosen: chosen)])
        Task {
            let sent = await answer(text, record)
            sending = false
            if sent { settled = record }
        }
    }
}

struct ClarifyEditField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        let placeholder = String(localized: "Edit your message…")
        PalTextField(
            "",
            text: $text,
            prompt: Text(placeholder),
            axis: .vertical
        )
        .lineLimit(1...8)
        .font(.body)
        .foregroundStyle(Color(theme.palette.textPrimary))
        .focused(focused)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: ChatMetrics.minimumHitTarget, alignment: .leading)
        .background(Color(theme.palette.chipFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(theme.palette.cardStroke), lineWidth: 1))
        .padding(.vertical, 2)
        .accessibilityLabel(Text(verbatim: placeholder))
        .accessibilityIdentifier("clarifyEditField")
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
            PalTextField(
                "",
                text: $text,
                prompt: Text(placeholder)
            )
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
