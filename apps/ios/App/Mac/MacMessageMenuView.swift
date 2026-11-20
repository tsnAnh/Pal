#if os(macOS)
import PalChat
import PalDesign
import SwiftUI

struct MacMessageMenuView: View {
    let actions: MessageActions
    let dismiss: () -> Void

    static let width = MessageMenuMetrics.cellWidth * 7 + 10
    private static let quickCount = 6

    private enum Page {
        case main
        case emoji
        case tables
    }

    @State private var page = Page.main

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 1) {
                switch page {
                case .main: mainPage
                case .emoji: emojiPage
                case .tables: tablesPage
                }
            }
            .padding(5)
            .frame(width: Self.width)
            .palGlass(shape, interactive: false)
        }
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        .background {
            Button("", action: dismiss)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("messageContextMenu")
    }

    @ViewBuilder
    private var mainPage: some View {
        let groups = actions.plan(offersSelectText: false).groups
        if actions.canReact() {
            reactionRow
            separator
        }
        ForEach(groups.indices, id: \.self) { index in
            if index > 0 { separator }
            ForEach(groups[index], id: \.self) { action in
                row(for: action)
            }
        }
    }

    private var emojiPage: some View {
        VStack(spacing: 4) {
            MacMenuRow(title: String(localized: "Back"), symbol: "arrow.left", identifier: "contextBack") { page = .main }
            separator
            EmojiPickerView(selected: actions.reaction, ink: actions.ink, columns: 8) { emoji in
                dismiss()
                actions.react(emoji)
            }
            .padding(.horizontal, 3)
        }
    }

    @ViewBuilder
    private var tablesPage: some View {
        MacMenuRow(title: String(localized: "Back"), symbol: "arrow.left", identifier: "contextBack") { page = .main }
        separator
        MacMenuRow(title: String(localized: "Copy as Markdown"), symbol: "doc.on.doc", identifier: "contextCopyTableMarkdown") {
            dismiss()
            MessageActionRunner.copyTables(actions, as: .markdown)
        }
        MacMenuRow(title: String(localized: "Copy as TSV"), symbol: "tablecells", identifier: "contextCopyTableTSV") {
            dismiss()
            MessageActionRunner.copyTables(actions, as: .tsv)
        }
    }

    private var separator: some View {
        PalHairline().padding(.vertical, 4).padding(.horizontal, 5)
    }

    private var reactionRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(ReactionCatalog.quick.prefix(Self.quickCount)), id: \.self) { emoji in
                reactionButton(emoji)
            }
            Button { page = .emoji } label: {
                PalIcon("plus", ink: .secondary)
                    .font(.system(size: MessageMenuMetrics.glyphSize + 1))
                    .frame(width: MessageMenuMetrics.cellWidth, height: MessageMenuMetrics.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("More reactions"))
            .help(Text("More reactions"))
            .accessibilityIdentifier("contextMoreReactions")
        }
    }

    private func reactionButton(_ emoji: String) -> some View {
        Button {
            dismiss()
            actions.react(emoji)
        } label: {
            Text(emoji)
                .font(.system(size: MessageMenuMetrics.emojiSize))
                .frame(width: MessageMenuMetrics.cellWidth, height: MessageMenuMetrics.rowHeight)
                .overlay {
                    if actions.reaction == emoji {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(actions.ink, lineWidth: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(emoji))
        .accessibilityIdentifier("contextReaction-\(emoji)")
    }

    @ViewBuilder
    private func row(for action: MessageAction) -> some View {
        let title = action.title(speakingRowID: MessageSpeaker.shared.speakingRowID, rowID: actions.rowID)
        switch action {
        case .share:
            ShareLink(item: actions.text) {
                MacMenuRowLabel(title: title, symbol: action.symbol)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(title))
            .accessibilityIdentifier(action.identifier)
        case .copyTable:
            MacMenuRow(title: title, symbol: action.symbol, identifier: action.identifier) { page = .tables }
        default:
            MacMenuRow(title: title, symbol: action.symbol, identifier: action.identifier) {
                dismiss()
                MessageActionRunner.perform(action, on: actions)
            }
        }
    }
}

private struct MacMenuRow: View {
    let title: String
    let symbol: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MacMenuRowLabel(title: title, symbol: symbol)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier(identifier)
    }
}

private struct MacMenuRowLabel: View {
    let title: String
    let symbol: String

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            PalIcon(symbol, ink: .secondary)
                .font(.system(size: MessageMenuMetrics.glyphSize))
                .frame(width: MessageMenuMetrics.glyphWidth)
            Text(title)
                .font(.system(size: MessageMenuMetrics.textSize))
                .foregroundStyle(PalTokens.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: MessageMenuMetrics.rowHeight)
        .background(hovering ? PalTokens.hover : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
#endif
