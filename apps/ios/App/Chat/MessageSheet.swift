#if os(iOS)
import PalChat
import PalDesign
import SwiftUI

private struct MessageSheetRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? PalTokens.selected : Color.clear)
    }
}

@MainActor
struct MessageSheet: View {
    private enum Page {
        case menu
        case emoji
        case selectText
        case tables
    }

    let actions: MessageActions
    let dismiss: () -> Void

    @State private var page = Page.menu
    @State private var plan: MessageActionPlan
    @State private var offersReactions: Bool
    @State private var contentHeight = Self.estimatedHeight

    private static let estimatedHeight: CGFloat = 420
    private static let selectTextMaxHeight: CGFloat = 360
    private static let reactionColumns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 6)

    init(actions: MessageActions, dismiss: @escaping () -> Void) {
        self.actions = actions
        self.dismiss = dismiss
        _plan = State(initialValue: actions.plan(offersSelectText: true))
        _offersReactions = State(initialValue: actions.canReact())
    }

    var body: some View {
        ScrollView {
            pageContent
                .transition(.opacity)
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .animation(.snappy(duration: 0.2), value: page)
        .presentationDetents([.height(contentHeight)])
        .presentationDragIndicator(.visible)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("messageContextMenu")
        .accessibilityAction(.escape) {
            if page == .menu { dismiss() } else { page = .menu }
        }
        .onAppear { MessageSpeaker.shared.stop() }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .menu:
            menuPage
        case .emoji:
            subpage(title: String(localized: "React")) {
                EmojiPickerView(selected: actions.reaction, ink: actions.ink, columns: 7) { emoji in
                    dismiss()
                    actions.react(emoji)
                }
            }
        case .selectText:
            subpage(title: MessageAction.selectText.title(speakingRowID: nil, rowID: actions.rowID)) {
                SelectableTextView(text: actions.text, maxHeight: Self.selectTextMaxHeight)
                    .frame(maxWidth: .infinity)
                    .background(PalTokens.chipFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        case .tables:
            subpage(title: MessageAction.copyTable.title(speakingRowID: nil, rowID: actions.rowID)) {
                tableFormats
            }
        }
    }

    private var menuPage: some View {
        VStack(spacing: 12) {
            if offersReactions { reactionGrid }
            ForEach(Array(plan.groups.enumerated()), id: \.offset) { _, group in
                card {
                    ForEach(Array(group.enumerated()), id: \.element) { index, action in
                        if index > 0 { PalHairline().padding(.leading, 16) }
                        row(action)
                    }
                }
            }
        }
    }

    private var reactionGrid: some View {
        LazyVGrid(columns: Self.reactionColumns, spacing: 4) {
            ForEach(MessageReactions.choices, id: \.self) { emoji in reactionCell(emoji) }
            Button { page = .emoji } label: {
                PalIcon("face.smiling")
                    .font(.title2)
                    .overlay(alignment: .topTrailing) {
                        PalIcon("plus")
                            .font(.system(size: 9, weight: .heavy))
                            .offset(x: 6, y: -3)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("More reactions"))
            .accessibilityIdentifier("contextMoreReactions")
        }
        .padding(.top, 4)
    }

    private func reactionCell(_ emoji: String) -> some View {
        Button {
            dismiss()
            actions.react(emoji)
        } label: {
            Text(emoji)
                .font(.title)
                .frame(maxWidth: .infinity, minHeight: 48)
                .overlay {
                    if actions.reaction == emoji {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(actions.ink, lineWidth: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(emoji))
        .accessibilityIdentifier("contextReaction-\(emoji)")
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(PalTokens.chipFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func row(_ action: MessageAction) -> some View {
        let title = action.title(speakingRowID: MessageSpeaker.shared.speakingRowID, rowID: actions.rowID)
        switch action {
        case .share:
            ShareLink(item: actions.text) { rowLabel(title: title, symbol: action.symbol) }
                .buttonStyle(MessageSheetRowStyle())
                .accessibilityIdentifier(action.identifier)
        case .selectText:
            rowButton(title: title, symbol: action.symbol, identifier: action.identifier) { page = .selectText }
        case .copyTable:
            rowButton(title: title, symbol: action.symbol, identifier: action.identifier) { page = .tables }
        case .reply, .markUnread, .markRead, .copy, .speak, .retry:
            rowButton(title: title, symbol: action.symbol, identifier: action.identifier) {
                MessageActionRunner.perform(action, on: actions)
                dismiss()
            }
        }
    }

    private func rowButton(title: String, symbol: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { rowLabel(title: title, symbol: symbol) }
            .buttonStyle(MessageSheetRowStyle())
            .accessibilityLabel(Text(title))
            .accessibilityIdentifier(identifier)
    }

    private func rowLabel(title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.body)
                .foregroundStyle(PalTokens.textPrimary)
            Spacer(minLength: 0)
            PalIcon(symbol)
                .font(.body)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: MessageMenuMetrics.rowHeight)
        .contentShape(Rectangle())
    }

    private var tableFormats: some View {
        card {
            rowButton(title: String(localized: "Copy as Markdown"), symbol: "doc.on.doc", identifier: "contextCopyTableMarkdown") {
                MessageActionRunner.copyTables(actions, as: .markdown)
                dismiss()
            }
            PalHairline().padding(.leading, 16)
            rowButton(title: String(localized: "Copy as TSV"), symbol: "tablecells", identifier: "contextCopyTableTSV") {
                MessageActionRunner.copyTables(actions, as: .tsv)
                dismiss()
            }
        }
    }

    private func subpage<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(PalTokens.textPrimary)
                HStack {
                    Button { page = .menu } label: {
                        Label("Back", palIcon: "chevron.backward")
                            .font(.body)
                            .foregroundStyle(PalTokens.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("messageSheetBack")
                    Spacer(minLength: 0)
                }
            }
            .frame(minHeight: MessageMenuMetrics.rowHeight)
            content()
        }
    }
}
#endif
