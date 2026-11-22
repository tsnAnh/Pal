import PalChat
import PalDesign
import SwiftUI

struct RoutineMessage: Equatable {
    let text: String
    let failureLead: String?
    let body: ParsedMarkdown

    init(body: String, failed: Bool) {
        let failure = failed ? InboundKind.splitFirstSentence(of: body) : nil
        let rest = failure?.rest ?? body
        text = body
        failureLead = failure?.lead
        self.body = ParsedMarkdown.cached(rest)
    }
}

struct RoutineOutputRow: View {
    let routine: RoutineMessage
    let highlight: String
    let isCurrentMatch: Bool

    var body: some View {
        AssistantBubble(
            text: routine.text, parsed: routine.body, failureLead: routine.failureLead,
            highlight: highlight, isCurrentMatch: isCurrentMatch
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FailureLead: View {
    let text: String
    let highlight: String
    let isCurrentMatch: Bool

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        if let block = ParsedMarkdown.cached(text).document.blocks.first {
            InlineText(text: block.text, highlight: highlight, isCurrentMatch: isCurrentMatch, foreground: Color(theme.palette.destructive))
        }
    }
}
