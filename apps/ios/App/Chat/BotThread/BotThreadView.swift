import PalChat
import PalDesign
import PalProtocol
import SwiftUI

struct BotThreadView: View {
    @State private var model: BotThreadModel
    @State private var isNearBottom = true
    @State private var scrollPosition = ScrollPosition()

    @Environment(\.hermesTheme) private var theme

    init(model: BotThreadModel) {
        _model = State(initialValue: model)
    }

    private var rows: [BotThreadEntry] {
        model.timeline.entries()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: ChatMetrics.rowSpacing) {
                    if model.timeline.hasOlder {
                        DelayedProgressView()
                            .frame(maxWidth: .infinity)
                            .onAppear { model.loadOlder() }
                            .accessibilityIdentifier("threadLoadingOlder")
                    }
                    if model.timeline.isOwnSideOnly {
                        coverageNote
                    }
                    ForEach(rows) { row in
                        BotThreadMessageRow(
                            row: row,
                            sender: model.timeline.participant(forSender: row.message.senderKey),
                            avatars: model.avatars
                        )
                        .id(row.id)
                        .onAppear {
                            if row.id == model.timeline.messages.last?.id { model.loadNewer() }
                        }
                    }
                    Color.clear.frame(height: ChatMetrics.threadPillHeight + 36)
                }
                .padding(.horizontal, ChatMetrics.edgeMargin)
                .padding(.top, 8)
            }
            .scrollPosition($scrollPosition)
            .scrollDismissesKeyboard(.interactively)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .accessibilityIdentifier("threadScreen")
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 160
            } action: { _, nearBottom in
                isNearBottom = nearBottom
            }
            .overlay { stateOverlay }
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    if !isNearBottom && !model.timeline.hasNewer {
                        ScrollToBottomButton { scrollToBottom() }
                            .transition(.scale.combined(with: .opacity))
                    }
                    ReadOnlyPill()
                }
                .padding(.bottom, 12)
            }
            .animation(.snappy(duration: 0.2), value: isNearBottom)
            .task(id: model.focusRequest) {
                guard let id = model.focusRequest else { return }
                await Task.yield()
                proxy.scrollTo(id, anchor: .top)
                model.consumeFocusRequest()
            }
            .onChange(of: model.timeline.messages.first?.id) { old, new in
                guard let old, old != new else { return }
                proxy.scrollTo(old, anchor: .top)
            }
            .onChange(of: model.timeline.messages.last?.id) { old, new in
                guard old != nil, new != old, isNearBottom, !model.timeline.hasNewer else { return }
                scrollToBottom()
            }
        }
        .background(Color(theme.palette.canvas))
        .toolbar {
            ToolbarItem(placement: .principal) {
                participantsCapsule
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .toolbarTitleDisplayMode(.inline)
        .task { model.start() }
        .onDisappear { model.stop() }
    }

    private func scrollToBottom() {
        withAnimation(.easeOut(duration: 0.2)) { scrollPosition.scrollTo(edge: .bottom) }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch model.state {
        case .loading where model.timeline.messages.isEmpty:
            DelayedProgressView().accessibilityIdentifier("threadLoading")
        case .loading:
            EmptyView()
        case .failed:
            Text("This conversation isn't available.")
                .hermesText(.chatStatus)
                .foregroundStyle(Color(theme.palette.textSecondary))
                .accessibilityIdentifier("threadUnavailable")
        case .ready:
            EmptyView()
        }
    }

    private var coverageNote: some View {
        Text("Replies from the other bot may be missing here.")
            .hermesText(.timestamp)
            .foregroundStyle(Color(theme.palette.textTertiary))
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.vertical, 6)
            .accessibilityIdentifier("threadCoverageNote")
    }

    private var participantsCapsule: some View {
        let participants = [model.owner, model.counterpart].compactMap { $0 }
        let size = ChatMetrics.threadHeaderAvatarSize
        return HStack(spacing: -size * 0.3) {
            ForEach(Array(participants.enumerated()), id: \.element.key) { index, participant in
                BotAvatarView(spec: model.avatars.spec(for: participant), size: size, animated: false)
                    .zIndex(Double(participants.count - index))
            }
        }
        .padding(.horizontal, 13)
        .frame(height: ChatMetrics.headerButtonDiameter)
        .palGlass(Capsule(), interactive: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(participants.map(\.displayName).formatted(.list(type: .and))))
        .accessibilityIdentifier("threadTitle")
    }
}

private let threadBubbleGap = ChatMetrics.bubbleTrailingGap - ChatMetrics.edgeMargin

private struct BotThreadMessageRow: View {
    let row: BotThreadEntry
    let sender: BotThreadParticipant?
    let avatars: ParticipantAvatars

    @Environment(\.hermesTheme) private var theme

    private var isFailure: Bool {
        row.message.status == .failed || row.message.status == .unknown || row.message.status == .pending
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let separator = row.separator {
                ChatTimeSeparator(text: ChatTimestamp.label(for: separator))
                    .accessibilityIdentifier("timeSeparator")
            }
            if row.showsName, let sender {
                Text(sender.displayName)
                    .hermesText(.chip)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .padding(.leading, ChatMetrics.threadAvatarSize + ChatMetrics.threadAvatarGap + ChatMetrics.threadNameInset)
                    .accessibilityIdentifier("threadSenderName")
            }
            HStack(alignment: .bottom, spacing: ChatMetrics.threadAvatarGap) {
                avatar
                ChatBubble(style: BubblePalette.agentBubble) {
                    MarkdownView(document: MarkdownDocument(parsing: row.message.text), highlight: "", isCurrentMatch: false)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(row.message.text))
                .accessibilityIdentifier("threadMessage")
                Spacer(minLength: threadBubbleGap)
            }
            if isFailure, let statusText = row.message.statusText {
                Label(statusText, systemImage: row.message.status == .pending ? "clock" : "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .padding(.leading, ChatMetrics.threadAvatarSize + ChatMetrics.threadAvatarGap + ChatMetrics.threadNameInset)
                    .accessibilityIdentifier("threadMessageStatus")
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if row.showsAvatar, let sender {
            BotAvatarView(spec: avatars.spec(for: sender), size: ChatMetrics.threadAvatarSize, animated: false)
        } else {
            Color.clear.frame(width: ChatMetrics.threadAvatarSize, height: ChatMetrics.threadAvatarSize)
        }
    }
}

private struct ReadOnlyPill: View {
    @Environment(\.hermesTheme) private var theme

    var body: some View {
        Label("Read-only", systemImage: "lock")
            .hermesText(.chip)
            .foregroundStyle(Color(theme.palette.textPrimary))
            .padding(.horizontal, 16)
            .frame(height: ChatMetrics.threadPillHeight)
            .palGlass(Capsule(), interactive: false)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("threadReadOnlyPill")
    }
}
