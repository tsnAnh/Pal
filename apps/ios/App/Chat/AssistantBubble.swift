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
    @Environment(\.messageActions) private var actions

    var body: some View {
        let segments = parsed.segments
        VStack(alignment: .leading, spacing: ChatMetrics.sameSenderGap) {
            if !images.isEmpty { ChatImageGrid(images: images).bubbleWidth(.leading) }
            if !text.isEmpty {
                if let failureLead, !startsWithText(segments) {
                    textBubble(nil, lead: failureLead, isFirst: true, label: text)
                }
                ForEach(segments) { segment in
                    segmentView(segment, isFirst: segment.id == segments.first?.id, single: segments.count == 1)
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

    private func startsWithText(_ segments: [MessageSegment]) -> Bool {
        if case .text = segments.first { true } else { false }
    }

    @ViewBuilder
    private func segmentView(_ segment: MessageSegment, isFirst: Bool, single: Bool) -> some View {
        switch segment {
        case .text(let textSegment):
            textBubble(textSegment, lead: isFirst ? failureLead : nil, isFirst: isFirst, label: single ? text : textSegment.spoken)
        case .table(_, let table):
            TableBubbleView(table: table, highlight: highlight, isCurrentMatch: isCurrentMatch)
                .messageActions(side: .assistant)
                .environment(\.messageActions, isFirst ? actions : actions?.withoutReaction)
        }
    }

    private func textBubble(_ segment: TextSegment?, lead: String?, isFirst: Bool, label: String) -> some View {
        ChatBubble(style: BubblePalette.agentBubble) {
            VStack(alignment: .leading, spacing: 8) {
                if let lead { FailureLead(text: lead, highlight: highlight, isCurrentMatch: isCurrentMatch) }
                if let segment {
                    MarkdownView(
                        segment: segment, wholeBubbleSelection: wholeBubbleSelection,
                        highlight: highlight, isCurrentMatch: isCurrentMatch, isStreaming: isStreaming
                    )
                }
            }
        }
        .bubbleAccessibility(text: label, identifier: "assistantBubble")
        .messageActions(side: .assistant)
        .environment(\.messageActions, isFirst ? actions : actions?.withoutReaction)
        .bubbleWidth(.leading)
    }
}

private extension MessageActions {
    var withoutReaction: MessageActions {
        MessageActions(rowID: rowID, text: text, reaction: nil, canReact: canReact, react: react, reply: reply)
    }
}

extension ParsedMarkdown {
    var segments: [MessageSegment] { deferred.segments }
}
