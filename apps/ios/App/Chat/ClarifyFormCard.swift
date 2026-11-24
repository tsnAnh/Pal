import PalChat
import PalDesign
import PalProtocol
import SwiftUI

struct ClarifyFormCard: View {
    let prompt: PendingPrompt
    var accent: BotAccent?
    let submit: ([(qid: String, answer: ClarifyForm.Answer)], ClarifySettled) async throws -> Void
    var edit: ((String, ClarifySettled) async throws -> Void)?

    @State private var form: ClarifyForm
    @State private var settling = false
    @State private var editing = false
    @FocusState private var otherFocused: Bool
    @FocusState private var cardFocused: Bool
    @Environment(\.hermesTheme) private var theme
    @Environment(\.composerActivity) private var composer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        prompt: PendingPrompt,
        accent: BotAccent? = nil,
        submit: @escaping ([(qid: String, answer: ClarifyForm.Answer)], ClarifySettled) async throws -> Void,
        edit: ((String, ClarifySettled) async throws -> Void)? = nil
    ) {
        self.prompt = prompt
        self.accent = accent
        self.submit = submit
        self.edit = edit
        _form = State(initialValue: ClarifyForm(questions: prompt.questions))
    }

    private var typedBinding: Binding<String> {
        Binding(get: { form.currentDraft.typed }, set: { form.setTyped($0) })
    }

    private var hasTyped: Bool {
        !form.currentDraft.typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isOwnerDecision: Bool { prompt.kind == .approval }

    private var confirmTitle: LocalizedStringKey? {
        if form.failure != nil { return "Retry" }
        if isOwnerDecision { return editing ? "Send" : nil }
        return form.needsConfirm ? "Done" : nil
    }

    private var locked: Bool { form.isSending || settling }

    private var settled: ClarifySettled? {
        guard form.isSending else { return nil }
        if isOwnerDecision, editing { return ClarifySettled(question: form.current.question, option: .send) }
        return ClarifySettled(form: form)
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
            ClarifyHeadline(text: form.current.question)
                .accessibilityLabel(Text("Question \(form.page + 1) of \(form.count), \(form.current.question)"))
            options
            textEntry
            footer
        }
        .id(form.page)
        .transition(.opacity)
        .clarifySurface()
        .animation(reduceMotion ? nil : .easeInOut(duration: Self.pageFade), value: form.page)
        .focusable()
        .focused($cardFocused)
        .focusEffectDisabled()
        .onKeyPress(.return) { handleKey { apply(form.confirm()) } }
        .onKeyPress(.leftArrow) { handleKey { goBack() } }
        .onKeyPress(.rightArrow) { handleKey { _ = form.advance() } }
        .onKeyPress(characters: .letters, phases: .down) { press in
            guard let letter = press.characters.first, let index = ClarifyForm.choiceIndex(forLetter: letter), form.hasChoices else { return .ignored }
            return handleKey { choose(index) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Back")) { goBack() }
        .accessibilityActions {
            if !isOwnerDecision { Button("Skip") { skip() } }
            if let confirmTitle { Button(confirmTitle) { confirm() } }
        }
        .accessibilityIdentifier("clarifyForm")
        .onChange(of: form.page) { _, page in
            AccessibilityNotification.Announcement(String(localized: "Question \(page + 1) of \(form.count), \(form.current.question)")).post()
        }
        .onAppear { cardFocused = ClarifyFocusPolicy.claimsFocus(composerFocused: composer.focused, draft: composer.draft) }
    }

    private var options: some View {
        ForEach(Array(form.current.choices.enumerated()), id: \.offset) { index, choice in
            let picked = form.currentDraft.picked.contains(index) || (editing && isEditOption(index))
            let showsCheck = picked && form.current.multiSelect
            Button { choose(index) } label: {
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
        if isOwnerDecision {
            if editing { ClarifyEditField(text: typedBinding, focused: $otherFocused) }
        } else if form.hasChoices {
            ClarifyInputRow(
                letter: ClarifyRow.letter(form.current.choices.count),
                text: typedBinding,
                focused: $otherFocused,
                hasText: hasTyped,
                accent: accent
            ) { confirm() }
        } else {
            ClarifyOpenField(text: typedBinding, focused: $otherFocused) { confirm() }
        }
    }

    private func handleKey(_ action: () -> Void) -> KeyPress.Result {
        guard !otherFocused, !locked else { return .ignored }
        action()
        return .handled
    }

    private func isEditOption(_ index: Int) -> Bool {
        isOwnerDecision && prompt.ownerOptions.indices.contains(index) && prompt.ownerOptions[index] == .edit
    }

    private func beginEdit() {
        guard let text = prompt.editableText else { return }
        editing = true
        if form.currentDraft.typed.isEmpty { form.setTyped(text) }
        otherFocused = true
    }

    private func choose(_ index: Int) {
        guard !locked else { return }
        if isEditOption(index) {
            beginEdit()
            return
        }
        editing = false
        cardFocused = true
        guard form.advancesOnPick, !reduceMotion else {
            apply(form.choose(index))
            return
        }
        form.pick(index)
        settling = true
        Task {
            try? await Task.sleep(for: .milliseconds(Self.settleMilliseconds))
            settling = false
            apply(form.choose(index))
        }
    }

    private func skip() {
        guard !locked, !isOwnerDecision else { return }
        apply(form.skipPage())
    }

    private func goBack() {
        cardFocused = true
        form.back()
    }

    private func jump(_ index: Int) {
        guard !locked else { return }
        cardFocused = true
        form.jump(to: index)
    }

    private func confirm() {
        apply(form.failure == nil ? form.confirm() : form.retry())
    }

    private func apply(_ step: ClarifyForm.Step) {
        guard step != .ignored, step != .stayed else { return }
        otherFocused = false
        cardFocused = true
        guard step == .submit, let payload = form.payload, let record = settled else { return }
        let edited = editedText(in: payload)
        Task {
            do {
                if let edited, let edit {
                    try await edit(edited, record)
                } else {
                    try await submit(payload, record)
                }
            } catch {
                form.submitFailed(error)
            }
        }
    }

    private func editedText(in payload: [(qid: String, answer: ClarifyForm.Answer)]) -> String? {
        guard editing, case .answered(let text)? = payload.first?.answer else { return nil }
        return text
    }

    private static let settleMilliseconds = 150
    private static let pageFade = 0.15
}

extension ClarifyFormCard {
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure = form.failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .accessibilityIdentifier("clarifyFailure")
            } else if form.isLast, !isOwnerDecision {
                Text(recapText)
                    .font(.footnote)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .accessibilityIdentifier("clarifyRecap")
            }
            if isOwnerDecision {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    confirmButton
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        ClarifyPageDots(count: form.count, current: form.page, canJump: form.canJump(to:), jump: jump)
                        Spacer(minLength: 8)
                        controls
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        ClarifyPageDots(count: form.count, current: form.page, canJump: form.canJump(to:), jump: jump)
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            controls
                        }
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
                .disabled(locked)
                .accessibilityIdentifier("clarifySkip")
            Button("Back") { goBack() }
                .glassButtonStyle()
                .disabled(form.isFirst || locked)
                .accessibilityIdentifier("clarifyBack")
            confirmButton
        }
    }

    @ViewBuilder
    private var confirmButton: some View {
        if let confirmTitle {
            Button(confirmTitle) { confirm() }
                .glassButtonStyle()
                .disabled(locked || (form.failure == nil && !form.canAdvance))
                .accessibilityIdentifier(form.failure == nil ? "clarifyConfirm" : "clarifyRetry")
        }
    }

    private var recapText: String {
        let recap = form.recap
        if recap.skipped == 0 { return String(localized: "\(recap.answered) answered") }
        return String(localized: "\(recap.answered) answered · \(recap.skipped) skipped")
    }
}

private struct ClarifyPageDots: View {
    let count: Int
    let current: Int
    let canJump: (Int) -> Bool
    let jump: (Int) -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                Button { jump(index) } label: {
                    Circle()
                        .fill(Color(index == current ? theme.palette.textPrimary : theme.palette.textTertiary))
                        .frame(width: 7, height: 7)
                        .padding(.horizontal, 5)
                        .frame(minHeight: ChatMetrics.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canJump(index))
                .accessibilityIdentifier("clarifyDot-\(index)")
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
        PalTextField(
            "",
            text: $text,
            prompt: Text(placeholder)
        )
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

struct ClarifyRowContent: View {
    let kind: ChatRow.Kind
    let accent: BotAccent?
    let model: ChatModel

    var body: some View {
        switch kind {
        case .clarifyAnswered(let records):
            ClarifySettledCard(settled: ClarifySettled(records: records)).bubbleWidth(.leading)
        case .clarify(let prompt) where prompt.isForm || prompt.kind == .approval:
            ClarifyFormCard(
                prompt: prompt,
                accent: accent,
                submit: { answers, settled in try await model.answerForm(prompt, answers, settled: settled) },
                edit: prompt.editableText == nil ? nil : { text, settled in try await model.answerEdit(prompt, text: text, settled: settled) }
            )
            .bubbleWidth(.leading)
        case .clarify(let prompt):
            ClarifyCard(prompt: prompt, accent: accent) { answer, settled in await model.answer(prompt, with: answer, settled: settled) }.bubbleWidth(.leading)
        default:
            EmptyView()
        }
    }
}
