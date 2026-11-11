import HermesChat
import HermesDesign
import HermesProtocol
import SwiftUI

struct ChatRowView: View {
    let row: ChatRow
    var previous: ChatRow?
    let model: ChatModel
    let openThread: (BotThreadLink) -> Void

    @Environment(\.hermesTheme) private var theme

    private var findQuery: String { model.isFinding ? model.findQuery : "" }
    private var isCurrentMatch: Bool { model.currentFindRowID == row.id }

    private var leadingGap: CGFloat {
        guard let previous, row.separator == nil, !row.showsUnreadDivider else { return 0 }
        guard let sender = row.sender, sender == previous.sender else { return ChatMetrics.senderSwitchGap }
        return ChatMetrics.sameSenderGap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if row.showsUnreadDivider {
                UnreadDivider(label: String(localized: "NEW"))
                    .accessibilityIdentifier("unreadDivider")
            }
            if let separator = row.separator {
                timeSeparator(separator)
                    .accessibilityIdentifier("timeSeparator")
            }
            content
        }
        .padding(.top, leadingGap)
    }

    private func timeSeparator(_ date: Date) -> some View {
        ChatTimeSeparator(text: ChatTimestamp.label(for: date))
    }

    private var imageLoader: ChatImageLoader {
        let model = model
        return { reference, thumbnail in try await model.loadImage(reference, thumbnail: thumbnail) }
    }

    private func messageActions(for text: String) -> MessageActions {
        let id = row.id
        let model = model
        return MessageActions(
            rowID: id,
            text: text,
            reaction: model.reactions[id],
            canReact: { model.canReact(to: id) },
            react: { model.react(to: id, with: $0) },
            reply: { model.beginReply(to: id) }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch row.kind {
        case .user(let text, let delivery):
            UserBubble(text: text, images: row.images, delivery: delivery, accent: model.chatAccent, highlight: findQuery, isCurrentMatch: isCurrentMatch) { id in
                model.retry(id)
            }
            .environment(\.messageActions, delivery == .sent ? messageActions(for: text) : nil)
            .environment(\.chatImageLoader, imageLoader)
        case .assistant(let text):
            AssistantBubble(text: text, images: row.images, highlight: findQuery, isCurrentMatch: isCurrentMatch)
                .environment(\.messageActions, messageActions(for: text))
                .environment(\.chatImageLoader, imageLoader)
        case .working(let status):
            ChatWorkingRow(status: status, accent: model.chatAccent)
        case .clarifyAnswered(let question, let answer):
            ClarifyAnsweredCard(question: question, answer: answer)
        case .clarify(let prompt):
            ClarifyCard(prompt: prompt) { answer in model.answer(prompt, with: answer) }
        case .approval(let prompt):
            ApprovalCard(prompt: prompt) { choice in model.answerApproval(prompt, choice: choice) }
        case .notice(let notice):
            NoticeRow(notice: notice, highlight: findQuery, isCurrentMatch: isCurrentMatch)
        case .botThread(let link):
            BotThreadLinkRow(link: link, avatars: model.avatars) { openThread(link) }
        case .imageGeneration(let generation):
            GeneratedImageRow(generation: generation)
                .environment(\.chatImageLoader, imageLoader)
        }
    }
}

struct AssistantBubble: View {
    let text: String
    var images: [ImageReference] = []
    let highlight: String
    let isCurrentMatch: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !images.isEmpty { ChatImageGrid(images: images) }
            if !text.isEmpty {
                ChatBubble(style: BubblePalette.agentBubble) {
                    MarkdownView(document: MarkdownDocument(parsing: text), highlight: highlight, isCurrentMatch: isCurrentMatch)
                        .bubbleTextSelection()
                }
                .bubbleAccessibility(text: text, identifier: "assistantBubble")
                .messageActions(side: .assistant)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .bubbleWidth(.leading)
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
    }

    @ViewBuilder
    private var status: some View {
        switch delivery {
        case .sent:
            EmptyView()
        case .sending:
            Label("Sending", systemImage: "arrow.up.circle")
                .font(.caption)
                .foregroundStyle(Color(theme.palette.textSecondary))
                .accessibilityIdentifier("deliverySending")
        case .waitingForConnection:
            Label("Waiting for connection", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(Color(theme.palette.textSecondary))
                .accessibilityIdentifier("deliveryWaitingForConnection")
        case .failed(let id):
            Button { retry(id) } label: {
                Label("Not sent. Tap to retry", systemImage: "exclamationmark.circle.fill")
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
    @State private var expanded = false

    private var title: String {
        switch notice {
        case .botMessage(let name, _): String(localized: "Message from \(name)")
        case .notification: String(localized: "Notification")
        case .backgroundTaskFinished(let count, _):
            count > 1 ? String(localized: "\(count) background tasks finished") : String(localized: "Background task finished")
        }
    }

    private var icon: String {
        switch notice {
        case .botMessage: "arrow.down.left.circle"
        case .notification: "bell"
        case .backgroundTaskFinished: "checkmark.circle"
        }
    }

    var body: some View {
        if case .backgroundTaskFinished(_, let text) = notice {
            backgroundTaskRow(text: text)
        } else {
            capsule
        }
    }

    private func backgroundTaskRow(text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 12))
                    Text(title).hermesText(.chip)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(expanded ? "Expanded" : "Collapsed"))
            .accessibilityIdentifier("inboundNotice")
            if expanded {
                Text(text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("backgroundTaskText")
            }
        }
        .foregroundStyle(Color(theme.palette.textSecondary))
        .padding(.vertical, 2)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var capsule: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12))
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
        return isCurrentMatch ? Color(theme.palette.primaryBadge).opacity(0.4) : Color.yellow.opacity(0.25)
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

    @ViewBuilder
    func bubbleTextSelection() -> some View {
        #if os(macOS)
        textSelection(.enabled)
        #else
        self
        #endif
    }
}
