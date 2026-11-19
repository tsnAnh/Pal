import PalChat
import PalDesign
import PalDiagnostics
import PalProtocol
import SwiftUI

struct ChatRowView: View {
    let row: ChatRow
    let context: ChatRowContext
    let model: ChatModel
    let openThread: (BotThreadLink) -> Void

    @Environment(\.hermesTheme) private var theme

    private var findQuery: String { context.findQuery }
    private var isCurrentMatch: Bool { context.isCurrentMatch }

    private var leadingGap: CGFloat {
        switch row.gap {
        case .none: 0
        case .sameSender: ChatMetrics.sameSenderGap
        case .senderSwitch: ChatMetrics.senderSwitchGap
        }
    }

    var body: some View {
        let _ = PalPerf.event("chat.row.body") // swiftlint:disable:this redundant_discardable_let
        VStack(alignment: .leading, spacing: 0) {
            if row.showsUnreadDivider {
                UnreadDivider(label: String(localized: "New"), ink: BubblePalette.ink(accent: context.accent))
                    .accessibilityIdentifier("unreadDivider")
            }
            if let separator = row.separator {
                timeSeparator(separator)
                    .accessibilityIdentifier("timeSeparator")
            }
            content
        }
        .padding(.top, leadingGap)
        .environment(\.chatImageOpener) { reference in model.openImage(reference, inRow: row.id) }
        .environment(\.chatFileOpener) { file in model.filePreview = file }
    }

    private func timeSeparator(_ date: Date) -> some View {
        ChatTimeSeparator(text: ChatTimestamp.label(for: date))
    }

    private func messageActions(for text: String) -> MessageActions {
        let id = row.id
        let model = model
        return MessageActions(
            rowID: id,
            text: text,
            reaction: context.reaction,
            canReact: { model.canReact(to: id) },
            react: { model.react(to: id, with: $0) },
            reply: { model.beginReply(to: id) }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch row.kind {
        case .user(let text, let delivery):
            UserBubble(text: text, images: row.images, delivery: delivery, accent: context.accent, highlight: findQuery, isCurrentMatch: isCurrentMatch) { id in
                model.retry(id)
            }
            .environment(\.messageActions, delivery == .sent ? messageActions(for: text) : nil)
            .environment(\.chatImageLoader, model.imageLoader)
        case .assistant(let parsed):
            AssistantBubble(
                text: parsed.source, parsed: parsed, images: row.images, files: row.files, filesPending: row.isStreaming,
                highlight: findQuery, isCurrentMatch: isCurrentMatch
            )
                .environment(\.messageActions, messageActions(for: parsed.source))
                .environment(\.chatImageLoader, model.imageLoader)
                .environment(\.chatFileActions, model.fileActions)
        case .clarifyAnswered, .clarify:
            ClarifyRowContent(kind: row.kind, accent: context.accent, model: model)
        case .approval(let prompt):
            ApprovalCard(prompt: prompt, ink: BubblePalette.ink(accent: context.accent), inkText: BubblePalette.inkText(accent: context.accent)) { choice in
                model.answerApproval(prompt, choice: choice)
            }
        case .approvalAnswered(let record):
            ApprovalAnsweredCard(record: record)
        case .connection(let card):
            ConnectionRequestCard(card: card, answering: context.answeringConnections) { target, decision in
                model.answerConnection(opID: card.operation.opID, target: target.name, decision: decision)
            }
        case .routine(let routine):
            RoutineOutputRow(routine: routine, highlight: findQuery, isCurrentMatch: isCurrentMatch)
                .environment(\.messageActions, messageActions(for: routine.text))
        case .notice(let notice):
            NoticeRow(notice: notice, highlight: findQuery, isCurrentMatch: isCurrentMatch)
        case .botThread(let link):
            BotThreadLinkRow(link: link, avatars: model.avatars) { openThread(link) }
        case .imageGeneration(let generation):
            GeneratedImageRow(generation: generation)
                .environment(\.chatImageLoader, model.imageLoader)
        }
    }
}

extension ChatRowView: @preconcurrency Equatable {
    static func == (lhs: ChatRowView, rhs: ChatRowView) -> Bool {
        lhs.row == rhs.row && lhs.context == rhs.context
    }
}

struct AssistantBubble: View {
    let text: String
    let parsed: ParsedMarkdown
    var images: [ImageReference] = []
    var files: [FileReference] = []
    var filesPending = false
    var failureLead: String?
    let highlight: String
    let isCurrentMatch: Bool
    var isStreaming: Bool = false

    @Environment(\.chatFileOpener) private var openFile

    @ViewBuilder
    private var bubbleContent: some View {
        if let failureLead {
            VStack(alignment: .leading, spacing: 8) {
                FailureLead(text: failureLead, highlight: highlight, isCurrentMatch: isCurrentMatch)
                if !parsed.document.blocks.isEmpty {
                    MarkdownView(parsed: parsed, highlight: highlight, isCurrentMatch: isCurrentMatch)
                }
            }
        } else {
            MarkdownView(parsed: parsed, highlight: highlight, isCurrentMatch: isCurrentMatch, isStreaming: isStreaming)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !images.isEmpty { ChatImageGrid(images: images) }
            if !text.isEmpty {
                ChatBubble(style: BubblePalette.agentBubble) {
                    bubbleContent.bubbleTextSelection()
                }
                .bubbleAccessibility(text: text, identifier: "assistantBubble")
                .messageActions(side: .assistant)
            }
            if !files.isEmpty { ChatFileStack(files: files, isStreaming: filesPending) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .bubbleWidth(.leading)
        .environment(\.openURL, OpenURLAction { url in
            let path = url.isFileURL ? url.path : (url.scheme == nil ? url.path : nil)
            guard let path, let file = files.first(where: { $0.path == path }), let openFile else { return .systemAction }
            openFile(file)
            return .handled
        })
    }
}

struct UserBubble: View {
    let text: String
    var images: [ImageReference] = []
    let delivery: BubbleDelivery
    let accent: BotAccent?
    let highlight: String
    let isCurrentMatch: Bool
    let retry: (String) -> Void

    @Environment(\.hermesTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var paint: (foreground: Color, background: Color) {
        (BubblePalette.userText, BubblePalette.userFill(accent: accent, isDark: colorScheme == .dark))
    }

    private var message: UserMessageParts { UserMessageParts(text) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if !images.isEmpty {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ChatImageGrid(images: images)
                }
                .bubbleWidth(.trailing)
            }
            if message.quote != nil || !message.body.isEmpty {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ChatBubble(fill: paint.background) {
                        VStack(alignment: .leading, spacing: 6) {
                            if let quote = message.quote {
                                UserQuoteBlock(text: quote, foreground: paint.foreground)
                            }
                            if !message.body.isEmpty {
                                InlineText(
                                    text: AttributedString(message.body),
                                    highlight: highlight,
                                    isCurrentMatch: isCurrentMatch,
                                    foreground: paint.foreground
                                )
                            }
                        }
                        .bubbleTextSelection()
                    }
                    .opacity(delivery == .sent ? 1 : 0.75)
                    .bubbleAccessibility(text: message.spoken, identifier: "userBubble")
                    .messageActions(side: .user)
                }
                .bubbleWidth(.trailing)
            }
            status
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .modifier(SendRise(isFresh: delivery == .sending))
    }

    @ViewBuilder
    private var status: some View {
        switch delivery {
        case .sent:
            EmptyView()
        case .sending:
            Label("Sending", palIcon: "arrow.up.circle", ink: .secondary)
                .font(.caption)
                .foregroundStyle(Color(theme.palette.textSecondary))
                .accessibilityIdentifier("deliverySending")
        case .waitingForConnection:
            Label("Waiting for connection", palIcon: "clock", ink: .secondary)
                .font(.caption)
                .foregroundStyle(Color(theme.palette.textSecondary))
                .accessibilityIdentifier("deliveryWaitingForConnection")
        case .failed(let id):
            Button { retry(id) } label: {
                Label("Not sent. Tap to retry", palIcon: "exclamationmark.circle.fill", ink: .destructive)
                    .font(.caption)
                    .foregroundStyle(Color(theme.palette.destructive))
            }
            .accessibilityIdentifier("deliveryFailed")
        }
    }
}

struct NoticeRow: View {
    let notice: ChatNotice
    let highlight: String
    let isCurrentMatch: Bool

    @Environment(\.hermesTheme) private var theme
    @Environment(\.chatInk) private var chatInk

    private var title: String {
        switch notice {
        case .botMessage(let name, _): String(localized: "Message from \(name)")
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            PalIcon("arrow.down.left.circle", ink: .secondary).font(.system(size: 12))
            Text(title).hermesText(.chip)
        }
        .foregroundStyle(Color(theme.palette.textSecondary))
        .padding(.vertical, 2)
        .padding(.horizontal, 10)
        .background(highlightFill, in: Capsule())
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier("inboundNotice")
    }

    private var highlightFill: Color {
        guard !highlight.isEmpty, case .botMessage(let name, let body) = notice,
              (name + " " + body).range(of: highlight, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        else { return .clear }
        return FindMark(ink: chatInk, surfaceText: nil, isCurrent: isCurrentMatch).fill
    }
}

struct BotThreadLinkRow: View {
    let link: BotThreadLink
    let avatars: ParticipantAvatars
    let open: () -> Void

    @Environment(\.hermesTheme) private var theme

    private var prefix: String {
        if link.count > 1 { return String(localized: "\(link.count) messages with") }
        return link.kind == .messaged ? String(localized: "Messaged") : String(localized: "Message from")
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 7) {
                Text(prefix)
                BotAvatarView(spec: avatars.spec(for: link.counterpart), size: ChatMetrics.linkAvatarSize, animated: false)
                Text(link.counterpart.displayName).lineLimit(1)
            }
            .hermesText(.chip)
            .foregroundStyle(Color(theme.palette.textSecondary))
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(prefix) \(link.counterpart.displayName)"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("botThreadLink")
    }
}

struct UserMessageParts: Equatable {
    let quote: String?
    let body: String

    init(_ text: String) {
        guard text.hasPrefix(">"), let split = text.range(of: "\n\n") else {
            quote = nil
            body = text
            return
        }
        let head = text[..<split.lowerBound]
        let lines = head.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.allSatisfy({ $0.hasPrefix(">") }) else {
            quote = nil
            body = text
            return
        }
        quote = lines.map { $0.dropFirst().drop(while: { $0 == " " }) }.joined(separator: " ")
        body = String(text[split.upperBound...])
    }

    var spoken: String { [quote, body.isEmpty ? nil : body].compactMap { $0 }.joined(separator: "\n") }
}

struct UserQuoteBlock: View {
    let text: String
    let foreground: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Capsule()
                .fill(foreground.opacity(0.55))
                .frame(width: 3)
            Text(text)
                .hermesText(.chatBody)
                .foregroundStyle(foreground.opacity(0.72))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

enum ChatTimestamp {
    static func label(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = ClockTime.label(for: date)
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Today \(time)") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday \(time)")
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= weekAgo {
            return "\(date.formatted(.dateTime.weekday(.wide))) \(time)"
        }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())) \(time)"
    }
}

extension ChatRow {
    enum Sender {
        case user
        case assistant
    }

    var sender: Sender? {
        switch kind {
        case .user: .user
        case .assistant: .assistant
        default: nil
        }
    }
}

private extension View {
    func bubbleAccessibility(text: String, identifier: String) -> some View {
        accessibilityElement(children: .ignore).accessibilityLabel(Text(text)).accessibilityIdentifier(identifier)
    }

    func bubbleTextSelection() -> some View {
        macOnly { $0.textSelection(.enabled) }
    }
}
