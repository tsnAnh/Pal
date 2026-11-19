import PalChat
import PalDesign
import PalProtocol
import SwiftUI

struct ClarifyFormCard: View {
    let prompt: PendingPrompt
    var accent: BotAccent?
    let submit: ([(qid: String, answer: ClarifyForm.Answer)]) async -> Bool

    @State private var form: ClarifyForm
    @State private var sending = false
    @FocusState private var otherFocused: Bool
    @FocusState private var cardFocused: Bool
    @Environment(\.hermesTheme) private var theme

    init(prompt: PendingPrompt, accent: BotAccent? = nil, submit: @escaping ([(qid: String, answer: ClarifyForm.Answer)]) async -> Bool) {
        self.prompt = prompt
        self.accent = accent
        self.submit = submit
        _form = State(initialValue: ClarifyForm(questions: prompt.questions))
    }

    private var typedBinding: Binding<String> {
        Binding(get: { form.currentDraft.typed }, set: { form.setTyped($0) })
    }

    private var hasTyped: Bool {
        !form.currentDraft.typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var primaryTitle: LocalizedStringKey { form.isLast ? "Submit" : "Next" }
    private var primaryEnabled: Bool { !sending && (form.isLast ? form.canSubmit : form.canAdvance) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ClarifyHeadline(text: form.current.question)
                .accessibilityLabel(Text("Question \(form.page + 1) of \(form.count), \(form.current.question)"))
            options
            textEntry
            footer
        }
        .clarifySurface()
        .focusable()
        .focused($cardFocused)
        .focusEffectDisabled()
        .onKeyPress(.return) { handleKey { advanceOrSubmit() } }
        .onKeyPress(.leftArrow) { handleKey { form.back() } }
        .onKeyPress(.rightArrow) { handleKey { advanceOrSubmit() } }
        .onKeyPress(characters: .letters, phases: .down) { press in
            guard let letter = press.characters.first, let index = ClarifyForm.choiceIndex(forLetter: letter), form.hasChoices else { return .ignored }
            return handleKey { pick(index) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Skip")) { skip() }
        .accessibilityAction(named: Text("Back")) { goBack() }
        .accessibilityAction(named: Text(primaryTitle)) { advanceOrSubmit() }
        .accessibilityIdentifier("clarifyForm")
    }

    private var options: some View {
        ForEach(Array(form.current.choices.enumerated()), id: \.offset) { index, choice in
            let picked = form.currentDraft.picked.contains(index)
            let showsCheck = picked && form.current.multiSelect
            Button { pick(index) } label: {
                ClarifyRow(
                    letter: showsCheck ? nil : ClarifyRow.letter(index),
                    text: choice,
                    style: picked ? .chosen : .choice,
                    accent: accent
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "\(ClarifyRow.letter(index)), \(choice)"))
            .accessibilityAddTraits(picked ? .isSelected : [])
            .accessibilityIdentifier("clarifyChoice-\(index)")
        }
    }

    @ViewBuilder
    private var textEntry: some View {
        if form.hasChoices {
            ClarifyInputRow(
                letter: ClarifyRow.letter(form.current.choices.count),
                text: typedBinding,
                focused: $otherFocused,
                hasText: hasTyped,
                accent: accent
            ) { advanceOrSubmit() }
        } else {
            ClarifyOpenField(text: typedBinding, focused: $otherFocused) { advanceOrSubmit() }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if form.isLast {
                Text(recapText)
                    .font(.footnote)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .accessibilityIdentifier("clarifyRecap")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ClarifyPageDots(count: form.count, current: form.page)
                    Spacer(minLength: 8)
                    controls
                }
                VStack(alignment: .leading, spacing: 0) {
                    ClarifyPageDots(count: form.count, current: form.page)
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        controls
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button("Skip") { skip() }
                .buttonStyle(.plain)
                .font(.footnote)
                .foregroundStyle(Color(theme.palette.textTertiary))
                .frame(minHeight: ChatMetrics.minimumHitTarget)
                .padding(.horizontal, 6)
                .disabled(sending)
                .accessibilityIdentifier("clarifySkip")
            Button("Back") { goBack() }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(form.isFirst || sending)
                .accessibilityIdentifier("clarifyBack")
            Button(primaryTitle) { advanceOrSubmit() }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(!primaryEnabled)
                .accessibilityIdentifier("clarifyNext")
        }
    }

    private var recapText: String {
        let recap = form.recap
        if recap.skipped == 0 { return String(localized: "\(recap.answered) answered") }
        return String(localized: "\(recap.answered) answered · \(recap.skipped) skipped")
    }

    private func handleKey(_ action: () -> Void) -> KeyPress.Result {
        guard !otherFocused, !sending else { return .ignored }
        action()
        return .handled
    }

    private func pick(_ index: Int) {
        cardFocused = true
        form.pick(index)
    }

    private func skip() {
        guard !sending else { return }
        cardFocused = true
        form.skip()
    }

    private func goBack() {
        cardFocused = true
        form.back()
    }

    private func advanceOrSubmit() {
        guard primaryEnabled else { return }
        otherFocused = false
        cardFocused = true
        guard form.isLast else {
            form.advance()
            return
        }
        guard let payload = form.payload else { return }
        sending = true
        Task {
            if await submit(payload) == false { sending = false }
        }
    }
}

private struct ClarifyPageDots: View {
    let count: Int
    let current: Int

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(Color(index == current ? theme.palette.textPrimary : theme.palette.textTertiary))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ClarifyOpenField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        let placeholder = String(localized: "Type your answer…")
        TextField(
            "",
            text: $text,
            prompt: Text(placeholder).foregroundStyle(Color(theme.palette.textTertiary))
        )
        .textFieldStyle(.plain)
        .focusEffectDisabled()
        .font(.body)
        .foregroundStyle(Color(theme.palette.textPrimary))
        .focused(focused)
        .submitLabel(.next)
        .onSubmit(onSubmit)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: ChatMetrics.minimumHitTarget, alignment: .leading)
        .background(Color(theme.palette.chipFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(theme.palette.cardStroke), lineWidth: 1))
        .padding(.vertical, 2)
        .accessibilityLabel(Text(verbatim: placeholder))
        .accessibilityIdentifier("clarifyOpenField")
    }
}

struct ClarifyAnsweredFormCard: View {
    let records: [ClarifyRecord]
    var accent: BotAccent?

    @Environment(\.hermesTheme) private var theme

    private func spoken(_ record: ClarifyRecord) -> String {
        if case .answered(let picks) = record.answer, !picks.isEmpty { return picks.joined(separator: ", ") }
        return String(localized: "Skipped")
    }

    private var spokenSummary: String {
        records.map { "\($0.question), \(spoken($0))" }.joined(separator: ". ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Answers sent")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(theme.palette.textPrimary))
                .padding(.bottom, 2)
            ForEach(Array(records.enumerated()), id: \.offset) { _, record in
                let skipped = spoken(record) == String(localized: "Skipped")
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    ClarifyBadge(letter: skipped ? "–" : nil, style: skipped ? .choice : .chosen, accent: accent)
                    Text(record.question)
                        .font(.footnote)
                        .foregroundStyle(Color(theme.palette.textSecondary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(spoken(record))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(skipped ? theme.palette.textTertiary : theme.palette.textPrimary))
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .clarifySurface()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spokenSummary))
        .accessibilityIdentifier("clarifyAnsweredForm")
    }
}

struct ClarifyRowContent: View {
    let kind: ChatRow.Kind
    let accent: BotAccent?
    let model: ChatModel

    var body: some View {
        switch kind {
        case .clarifyAnswered(let records) where records.count == 1:
            ClarifyAnsweredCard(question: records[0].question, answer: records[0].answer, accent: accent).bubbleWidth(.leading)
        case .clarifyAnswered(let records):
            ClarifyAnsweredFormCard(records: records, accent: accent).bubbleWidth(.leading)
        case .clarify(let prompt) where prompt.isForm:
            ClarifyFormCard(prompt: prompt, accent: accent) { answers in await model.answerForm(prompt, answers) }.bubbleWidth(.leading)
        case .clarify(let prompt):
            ClarifyCard(prompt: prompt, accent: accent) { answer in model.answer(prompt, with: answer) }.bubbleWidth(.leading)
        default:
            EmptyView()
        }
    }
}
