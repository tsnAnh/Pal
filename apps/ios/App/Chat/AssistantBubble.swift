import PalChat
import PalDesign
import SwiftUI

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
    var wholeBubbleSelection = false

    @Environment(\.chatFileOpener) private var openFile

    var body: some View {
        let segments = parsed.segments
        let leadsAlone = failureLead != nil && !startsWithText(segments)
        let carrier = leadsAlone ? nil : (segments.first(where: isText) ?? segments.first)?.id
        VStack(alignment: .leading, spacing: ChatMetrics.sameSenderGap) {
            if !images.isEmpty { ChatImageGrid(images: images).bubbleWidth(.leading) }
            if !text.isEmpty {
                if leadsAlone, let failureLead {
                    textBubble(nil, lead: failureLead, carries: true, label: text)
                }
                ForEach(segments) { segment in
                    segmentView(
                        segment, leadsMessage: segment.id == segments.first?.id,
                        carries: segment.id == carrier, single: segments.count == 1
                    )
                }
            }
            if !files.isEmpty { ChatFileStack(files: files, isStreaming: filesPending).bubbleWidth(.leading) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            let path = url.isFileURL ? url.path : (url.scheme == nil ? url.path : nil)
            guard let path, let file = files.first(where: { $0.path == path }), let openFile else { return .systemAction }
            openFile(file)
            return .handled
        })
    }

    private func isText(_ segment: MessageSegment) -> Bool {
        if case .text = segment { true } else { false }
    }

    private func startsWithText(_ segments: [MessageSegment]) -> Bool {
        segments.first.map(isText) ?? false
    }

    @ViewBuilder
    private func segmentView(_ segment: MessageSegment, leadsMessage: Bool, carries: Bool, single: Bool) -> some View {
        switch segment {
        case .text(let textSegment):
            textBubble(textSegment, lead: leadsMessage ? failureLead : nil, carries: carries, label: single ? text : textSegment.spoken)
        case .table(_, let table):
            withActions(TableBubbleView(table: table, highlight: highlight, isCurrentMatch: isCurrentMatch), carries, placement: .insideBubble)
        }
    }

    @ViewBuilder
    private func withActions<Bubble: View>(_ bubble: Bubble, _ carries: Bool, placement: MessageChromePlacement = .beside) -> some View {
        if carries { bubble.messageActions(side: .assistant, placement: placement) } else { bubble }
    }

    private func leadView(_ lead: String) -> some View {
        FailureLead(text: lead, highlight: highlight, isCurrentMatch: isCurrentMatch).bubbleTextSelection()
    }

    private func textBubble(_ segment: TextSegment?, lead: String?, carries: Bool, label: String) -> some View {
        let bubble = ChatBubble(style: BubblePalette.agentBubble) {
            VStack(alignment: .leading, spacing: 8) {
                if let lead { leadView(lead) }
                if let segment {
                    MarkdownView(
                        segment: segment, wholeBubbleSelection: wholeBubbleSelection,
                        highlight: highlight, isCurrentMatch: isCurrentMatch, isStreaming: isStreaming
                    )
                }
            }
        }
        .bubbleAccessibility(text: label, identifier: "assistantBubble")
        return withActions(bubble, carries).bubbleWidth(.leading)
    }
}

extension ParsedMarkdown {
    var segments: [MessageSegment] { deferred.segments }
}
