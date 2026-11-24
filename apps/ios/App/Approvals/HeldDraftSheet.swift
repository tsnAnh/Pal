import PalChat
import PalDesign
import SwiftUI

struct HeldDraftSheet: View {
    @Bindable var model: HeldDraftSheetModel

    @Environment(\.hermesTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: ChatMetrics.sameSenderGap) {
            Text(model.headerLine)
                .font(.footnote)
                .foregroundStyle(Color(theme.palette.textSecondary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("heldDraftHeader")
            ChatBubble(style: BubblePalette.agentBubble) {
                Text(verbatim: model.shownText)
                    .font(.body)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .bubbleWidth(.leading)
            .accessibilityIdentifier("heldDraftBubble")
            card
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: model.phase)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("heldDraftSheet")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch model.phase {
            case .editing: editor
            case .waiting, .sending, .failed: decision
            case .sent, .cancelled, .expired, .unavailable: outcome
            }
            if let problem = model.problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .padding(.top, 4)
                    .accessibilityIdentifier("heldDraftProblem")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .palClearGlass(RoundedRectangle(cornerRadius: ChatMetrics.bubbleRadius, style: .continuous), interactive: false)
        .bubbleWidth(.leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("heldDraftCard")
    }

    @ViewBuilder
    private var decision: some View {
        if case .failed = model.phase {
            status
        } else if model.phase == .sending {
            ClarifyHeadline(text: String(localized: "Send this message?"))
            status
        } else {
            ClarifyHeadline(text: String(localized: "Send this message?"))
            Text("Nothing is sent until you choose Send.")
                .font(.footnote)
                .foregroundStyle(Color(theme.palette.textSecondary))
                .padding(.bottom, 4)
        }
        let again: Bool = if case .failed = model.phase { true } else { false }
        choice(again ? String(localized: "Send again") : String(localized: "Send"), id: again ? "heldDraftSendAgain" : "heldDraftSend", enabled: model.canSend) {
            await model.send()
        }
        if !again {
            choice(String(localized: "Edit"), id: "heldDraftEdit", enabled: model.canEdit) {
                model.beginEdit()
                fieldFocused = true
            }
        }
        choice(String(localized: "Cancel"), id: "heldDraftCancel", enabled: model.canChoose) { await model.cancel() }
    }

    @ViewBuilder
    private var editor: some View {
        ClarifyHeadline(text: String(localized: "Edit before sending"))
        Text("Only the text changes, not who gets it.")
            .font(.footnote)
            .foregroundStyle(Color(theme.palette.textSecondary))
            .padding(.bottom, 4)
        PalTextField("", text: $model.editText, prompt: Text(String(localized: "Edit your message…")), axis: .vertical)
            .lineLimit(1...10)
            .font(.body)
            .foregroundStyle(Color(theme.palette.textPrimary))
            .focused($fieldFocused)
            .frame(minHeight: ChatMetrics.minimumHitTarget, alignment: .topLeading)
            .accessibilityLabel(Text("Message text"))
            .accessibilityIdentifier("heldDraftEditField")
        choice(String(localized: "Send edited"), id: "heldDraftSendEdited", enabled: model.canSendEdited) { await model.sendEdited() }
        choice(String(localized: "Back"), id: "heldDraftBack", enabled: model.inFlight == nil) { model.back() }
    }

    @ViewBuilder
    private var outcome: some View {
        status
        if model.canDiscard {
            choice(String(localized: "Discard"), id: "heldDraftDiscard", enabled: true) { await model.cancel() }
        }
    }

    @ViewBuilder
    private var status: some View {
        if let line = model.statusLine {
            Text(line)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color(theme.palette.textPrimary))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
                .accessibilityIdentifier("heldDraftStatus")
        }
        if let detail = model.detailLine {
            Text(detail)
                .font(.footnote)
                .foregroundStyle(Color(theme.palette.textSecondary))
                .accessibilityIdentifier("heldDraftDetail")
        }
    }

    private func choice(_ title: String, id: String, enabled: Bool, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color(theme.palette.textPrimary))
                .frame(maxWidth: .infinity, minHeight: ChatMetrics.minimumHitTarget, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityIdentifier(id)
    }
}
