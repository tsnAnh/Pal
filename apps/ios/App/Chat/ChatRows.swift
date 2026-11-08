import HermesChat
import HermesDesign
import HermesProtocol
import SwiftUI

struct ChatRowView: View {
    let row: ChatRow
    let model: ChatModel
    let openThread: (BotThreadLink) -> Void

    @Environment(\.hermesTheme) private var theme

    private var findQuery: String { model.isFinding ? model.findQuery : "" }
    private var isCurrentMatch: Bool { model.currentFindRowID == row.id }

    var body: some View {
        VStack(alignment: .leading, spacing: ChatMetrics.rowSpacing) {
            if row.showsUnreadDivider {
                UnreadDivider(label: String(localized: "NEW"))
                    .accessibilityIdentifier("unreadDivider")
            }
            if let separator = row.separator {
                ChatTimeSeparator(text: ChatTimestamp.label(for: separator))
                    .accessibilityIdentifier("timeSeparator")
            }
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch row.kind {
        case .user(let text, let delivery):
            UserBubble(text: text, delivery: delivery, accent: model.chatAccent, highlight: findQuery, isCurrentMatch: isCurrentMatch) { id in
                model.retry(id)
            }
        case .assistant(let text, let streaming):
            AssistantBubble(text: text, isStreaming: streaming, highlight: findQuery, isCurrentMatch: isCurrentMatch)
        case .tool(let name, let summary, let running):
            ToolLine(name: name, summary: summary, isRunning: running)
        case .clarify(let prompt):
            ClarifyCard(prompt: prompt) { answer in model.answer(prompt, with: answer) }
        case .approval(let prompt):
            ApprovalCard(prompt: prompt) { choice in model.answerApproval(prompt, choice: choice) }
        case .notice(let notice):
            NoticeRow(notice: notice, highlight: findQuery, isCurrentMatch: isCurrentMatch)
        case .botThread(let link):
            BotThreadLinkRow(link: link, avatars: model.avatars) { openThread(link) }
        }
    }
}

private let bubbleGapInsideMargins = ChatMetrics.bubbleTrailingGap - ChatMetrics.edgeMargin

struct AssistantBubble: View {
    let text: String
    let isStreaming: Bool
    let highlight: String
    let isCurrentMatch: Bool

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            ChatBubble(fill: Color(theme.palette.assistantBubble)) {
                MarkdownView(document: MarkdownDocument(parsing: text), highlight: highlight, isCurrentMatch: isCurrentMatch)
                    .textSelection(.enabled)
            }
            Spacer(minLength: bubbleGapInsideMargins)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(text))
        .accessibilityIdentifier(isStreaming ? "assistantBubble-streaming" : "assistantBubble")
    }
}

struct UserBubble: View {
    let text: String
    let delivery: BubbleDelivery
    let accent: BotAccent?
    let highlight: String
    let isCurrentMatch: Bool
    let retry: (String) -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 0) {
                Spacer(minLength: bubbleGapInsideMargins)
                ChatBubble(fill: accent?.accent ?? Color(theme.palette.userBubble)) {
                    InlineText(
                        text: AttributedString(text),
                        highlight: highlight,
                        isCurrentMatch: isCurrentMatch,
                        foreground: accent?.foreground ?? Color(theme.palette.userBubbleText)
                    )
                    .textSelection(.enabled)
                }
                .opacity(delivery == .sent ? 1 : 0.75)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(text))
            .accessibilityIdentifier("userBubble")
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
        case .queued:
            Label("Queued, will send when online", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(Color(theme.palette.textSecondary))
                .accessibilityIdentifier("deliveryQueued")
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

    private var title: String {
        switch notice {
        case .botMessage(let name, _): String(localized: "Message from \(name)")
        case .notification: String(localized: "Notification")
        case .backgroundTaskFinished: String(localized: "Background task finished")
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
