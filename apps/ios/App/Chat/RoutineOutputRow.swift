import PalChat
import PalDesign
import SwiftUI

struct RoutineMessage: Equatable {
    let jobName: String
    let time: Date?
    let text: String
    let failureLead: String?
    let body: ParsedMarkdown

    init(jobName: String, body: String, failed: Bool, time: Date?) {
        let failure = failed ? InboundKind.splitFirstSentence(of: body) : nil
        let rest = failure?.rest ?? body
        self.jobName = jobName
        self.time = time
        text = body
        failureLead = failure?.lead
        self.body = ParsedMarkdown(source: rest, document: MarkdownDocument(parsing: rest))
    }
}

struct RoutineOutputRow: View {
    let routine: RoutineMessage
    let highlight: String
    let isCurrentMatch: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RoutineSenderLine(jobName: routine.jobName, time: routine.time)
            AssistantBubble(
                text: routine.text, parsed: routine.body, failureLead: routine.failureLead,
                highlight: highlight, isCurrentMatch: isCurrentMatch
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FailureLead: View {
    let text: String
    let highlight: String
    let isCurrentMatch: Bool

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        if let block = MarkdownDocument(parsing: text).blocks.first {
            InlineText(text: block.text, highlight: highlight, isCurrentMatch: isCurrentMatch, foreground: Color(theme.palette.destructive))
        }
    }
}

struct RoutineSenderLine: View {
    let jobName: String
    let time: Date?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 12))
                .foregroundStyle(PalTokens.textSecondary)
                .frame(width: 22, height: 22)
                .background(PalTokens.control, in: Circle())
            if !jobName.isEmpty {
                Text(jobName)
                    .fontWeight(.semibold)
                    .hermesText(.chatBody)
                    .foregroundStyle(PalTokens.textPrimary)
                    .lineLimit(1)
            }
            if let time {
                Text(ClockTime.label(for: time))
                    .hermesText(.timestamp)
                    .foregroundStyle(PalTokens.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("routineSender")
    }
}
