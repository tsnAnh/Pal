import HermesDesign
import HermesProtocol
import HermesRoster
import SwiftUI

struct ChatView: View {
    @State private var model: ChatModel
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    init(model: ChatModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.rows) { row in
                        ChatRowView(row: row, model: model)
                            .id(row.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("chatScreen")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Composer(botName: model.bot.displayName, draft: $draft, focused: $composerFocused) {
                    model.send(draft)
                    draft = ""
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .overlay {
            if model.isOffline {
                ProgressView()
                    .controlSize(.large)
                    .accessibilityLabel(Text("Reconnecting"))
                    .accessibilityIdentifier("reconnectingIndicator")
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                BotCapsule(bot: model.bot, activity: model.activity, mood: model.avatarMood)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .toolbarTitleDisplayMode(.inline)
        .background(Color.canvas)
        .task { model.start() }
        .onDisappear { model.stop() }
        .alert(
            Text("Something went wrong"),
            isPresented: Binding(get: { model.sendError != nil }, set: { if !$0 { model.dismissError() } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.sendError ?? "")
        }
    }
}

private struct BotCapsule: View {
    let bot: BotRow
    let activity: BotActivity
    let mood: AvatarMood

    var body: some View {
        HStack(spacing: 8) {
            BotAvatarView(spec: bot.spec, size: 28, mood: mood)
                .opacity(activity.avatarOpacity)
            Text(bot.displayName)
                .font(.headline)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(bot.displayName))
        .accessibilityValue(Text(activity.accessibilityValue))
        .accessibilityIdentifier("chatTitle")
    }
}

private struct Composer: View {
    let botName: String
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    let send: () -> Void

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button {} label: {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: 52, height: 52)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(true)
            .accessibilityLabel(Text("Add attachment"))
            .accessibilityIdentifier("attachButton")
            HStack(alignment: .bottom, spacing: 6) {
                TextField("", text: $draft, prompt: Text("Ask \(botName)"), axis: .vertical)
                    .lineLimit(1...5)
                    .focused(focused)
                    .submitLabel(.send)
                    .onSubmit { if canSend { send() } }
                    .padding(.leading, 18)
                    .padding(.vertical, 15)
                    .accessibilityLabel(Text("Message \(botName)"))
                    .accessibilityIdentifier("composerField")
                Image(systemName: "mic")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 52)
                    .accessibilityHidden(true)
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.onAction)
                        .frame(width: 42, height: 42)
                        .background(Color.action, in: Circle())
                }
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.4)
                .padding(.trailing, 5)
                .padding(.bottom, 5)
                .accessibilityLabel(Text("Send"))
                .accessibilityIdentifier("sendButton")
            }
            .frame(minHeight: 52)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct ChatRowView: View {
    let row: ChatRow
    let model: ChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let separator = row.separator {
                Text(ChatTimestamp.label(for: separator))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("timeSeparator")
            }
            switch row.kind {
            case .user(let text, let delivery):
                UserBubble(text: text, delivery: delivery, accent: model.bot.accent) { id in model.retry(id) }
            case .assistant(let text, let streaming):
                AssistantBubble(text: text, isStreaming: streaming)
            case .tool(let name, let summary, let running):
                ToolLine(name: name, summary: summary, isRunning: running)
            case .clarify(let prompt):
                ClarifyCard(prompt: prompt) { answer in model.answer(prompt, with: answer) }
            case .approval(let prompt):
                ApprovalCard(prompt: prompt) { choice in model.answerApproval(prompt, choice: choice) }
            }
        }
    }
}

private enum Markdown {
    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private struct AssistantBubble: View {
    let text: String
    let isStreaming: Bool

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if text.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    Text(Markdown.attributed(text))
                        .font(.body)
                        .foregroundStyle(Color.onCard)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .containerRelativeFrame(.horizontal, alignment: .leading) { width, _ in width * 0.85 }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(text.isEmpty ? String(localized: "Thinking") : text))
        .accessibilityIdentifier(isStreaming ? "assistantBubble-streaming" : "assistantBubble")
    }
}

private struct UserBubble: View {
    let text: String
    let delivery: BubbleDelivery
    let accent: BotAccent?
    let retry: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var paint: (foreground: Color, background: Color) {
        guard let accent else { return (.white, .blue) }
        guard colorScheme == .light, AvatarColor(css: accent.accentHex)?.isWhite == true,
              let ink = AvatarColor(css: AvatarColor.darkEyeFillCSS), let onInk = AvatarColor(css: AvatarColor.lightEyeFillCSS)
        else { return (accent.foreground, accent.accent) }
        return (onInk.swiftUIColor, ink.swiftUIColor)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(Markdown.attributed(text))
                .font(.body)
                .foregroundStyle(paint.foreground)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(paint.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .opacity(delivery == .sent ? 1 : 0.75)
                .accessibilityIdentifier("userBubble")
            status
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var status: some View {
        switch delivery {
        case .sent:
            EmptyView()
        case .sending:
            Label("Sending", systemImage: "arrow.up.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("deliverySending")
        case .queued:
            Label("Queued, will send when online", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("deliveryQueued")
        case .failed(let id):
            Button { retry(id) } label: {
                Label("Not sent. Tap to retry", systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            .accessibilityIdentifier("deliveryFailed")
        }
    }
}

private struct ToolLine: View {
    let name: String
    let summary: String?
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isRunning {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "wrench.and.screwdriver").font(.caption)
            }
            Text(summary.flatMap { $0.isEmpty ? nil : $0 } ?? name)
                .font(.footnote)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(isRunning ? "Running \(name)" : "Used \(name)"))
    }
}

private struct ClarifyCard: View {
    let prompt: PendingPrompt
    let answer: (String) -> Void

    @State private var selection: Set<Int> = []

    private var isMulti: Bool { prompt.multiSelect == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    Text(prompt.question ?? String(localized: "Question"))
                        .font(.headline)
                        .foregroundStyle(Color.onCard)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { answer("") } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
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
                                .foregroundStyle(selection.contains(index) ? Color.onAction : Color.secondary)
                                .frame(width: 30, height: 30)
                                .background(
                                    selection.contains(index) ? Color.action : Color.chip,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.chipOutline, lineWidth: 1))
                            Text(choice)
                                .font(.body)
                                .foregroundStyle(Color.onCard)
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
                        .buttonStyle(.glass)
                        .disabled(selection.isEmpty)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("clarifyConfirm")
                }
            }
            .padding(16)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.cardOutline, lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("clarifyCard")
            Text("Or answer in the chat below")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.leading, 6)
        }
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

private struct ApprovalCard: View {
    let prompt: PendingPrompt
    let choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt.description ?? String(localized: "Approval needed"))
                .font(.headline)
                .foregroundStyle(Color.onCard)
            if let command = prompt.command {
                Text(command)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(prompt.choices.enumerated()), id: \.offset) { index, choice in
                Button(choice) { choose(choice) }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("approvalChoice-\(index)")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.cardOutline, lineWidth: 1))
    }
}

enum ChatTimestamp {
    static func label(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().locale(Locale(identifier: "en_GB")))
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Today \(time)") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday \(time)")
        }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())) \(time)"
    }
}
