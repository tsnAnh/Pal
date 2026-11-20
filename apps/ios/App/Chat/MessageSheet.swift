#if os(iOS)
import PalChat
import PalDesign
import SwiftUI

struct MessageSheetDim: View {
    let anchor: CGRect
    let dismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            MessageSheetDimShape(hole: anchor.offsetBy(dx: -origin.x, dy: -origin.y))
                .fill(PalTokens.scrim.opacity(0.5), style: FillStyle(eoFill: true))
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

private struct MessageSheetDimShape: Shape {
    let hole: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if !hole.isEmpty {
            path.addPath(Path(roundedRect: hole, cornerRadius: 18, style: .continuous))
        }
        return path
    }
}

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
    let maxContentHeight: CGFloat
    let dismiss: () -> Void

    @State private var page = Page.menu
    @State private var plan: MessageActionPlan
    @State private var offersReactions: Bool
    @State private var dragOffset: CGFloat = 0

    private static let reactionColumns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 6)
    private static let shape = UnevenRoundedRectangle(
        topLeadingRadius: 26,
        bottomLeadingRadius: 0,
        bottomTrailingRadius: 0,
        topTrailingRadius: 26,
        style: .continuous
    )

    init(actions: MessageActions, maxContentHeight: CGFloat, dismiss: @escaping () -> Void) {
        self.actions = actions
        self.maxContentHeight = maxContentHeight
        self.dismiss = dismiss
        _plan = State(initialValue: actions.plan(offersSelectText: true))
        _offersReactions = State(initialValue: actions.canReact())
    }

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 0) {
                grabber
                pageContent
                    .transition(.opacity)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .background {
                Color.clear
                    .palGlass(Self.shape, interactive: false)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        .animation(.snappy(duration: 0.2), value: page)
        .offset(y: dragOffset)
        .gesture(dismissDrag, including: page == .menu ? .all : .subviews)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("messageContextMenu")
        .accessibilityAction(.escape) {
            if page == .menu { dismiss() } else { page = .menu }
        }
        .onAppear { MessageSpeaker.shared.stop() }
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global) // scroll-gesture: ok modal sheet over a dimmed chat
            .onChanged { dragOffset = max(0, $0.translation.height) }
            .onEnded { value in
                if value.translation.height > 90 || value.predictedEndTranslation.height > 220 {
                    dismiss()
                } else {
                    withAnimation(.snappy) { dragOffset = 0 }
                }
            }
    }

    private var grabber: some View {
        Capsule()
            .fill(PalTokens.textTertiary)
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity, minHeight: 24)
            .contentShape(Rectangle())
            .gesture(dismissDrag)
            .accessibilityHidden(true)
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
                SelectableTextView(text: actions.text, maxHeight: maxContentHeight)
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
