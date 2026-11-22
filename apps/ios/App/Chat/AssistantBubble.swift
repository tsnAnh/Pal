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
    @State private var links = FileLinkRouter()

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
        .environment(\.openURL, links.action(files: files, open: openFile))
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

@MainActor
private final class FileLinkRouter {
    private var files: [FileReference] = []
    private var open: (@MainActor (FileReference) -> Void)?
    private lazy var routing = OpenURLAction { [weak self] url in self?.route(url) ?? .systemAction }

    func action(files: [FileReference], open: (@MainActor (FileReference) -> Void)?) -> OpenURLAction {
        self.files = files
        self.open = open
        return routing
    }

    private func route(_ url: URL) -> OpenURLAction.Result {
        let path = url.isFileURL ? url.path : (url.scheme == nil ? url.path : nil)
        guard let path, let file = files.first(where: { $0.path == path }), let open else { return .systemAction }
        open(file)
        return .handled
    }
}

extension ParsedMarkdown {
    static func deferringWarm(_ source: String, isStreaming: Bool) -> ParsedMarkdown {
        let parsed = ParsedMarkdown(deferring: source)
        if !isStreaming {
            MarkdownWarmer.shared.enqueue(parsed.deferred)
            #if os(macOS)
            SelectableTextPrefetcher.shared.enqueue(parsed.deferred)
            #endif
        }
        return parsed
    }

    var segments: [MessageSegment] { deferred.segments }
}
