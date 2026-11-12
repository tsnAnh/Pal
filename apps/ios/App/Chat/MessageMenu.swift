import PalDesign
import SwiftUI

enum MessageMenuMetrics {
    #if os(macOS)
    static let width: CGFloat = 205
    static let rowHeight: CGFloat = 30
    static let cellWidth: CGFloat = 32
    static let emojiSize: CGFloat = 17
    static let glyphSize: CGFloat = 12
    static let glyphWidth: CGFloat = 16
    static let textSize: CGFloat = 13
    static let radius: CGFloat = 12
    #else
    static let width: CGFloat = 268
    static let rowHeight: CGFloat = 44
    static let cellWidth: CGFloat = 42
    static let emojiSize: CGFloat = 23
    static let glyphSize: CGFloat = 15
    static let glyphWidth: CGFloat = 22
    static let textSize: CGFloat = 16
    static let radius: CGFloat = 16
    #endif
}

struct MessageMenuSurface: ViewModifier {
    let identifier: String

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: MessageMenuMetrics.radius, style: .continuous) }

    func body(content: Content) -> some View {
        content
            .padding(5)
            .palGlass(shape, interactive: false)
            .overlay(shape.strokeBorder(PalTokens.panelBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
    }
}

struct MessageMenu: View {
    let actions: MessageActions
    let dismiss: () -> Void

    private static let extras = ["😮", "😢", "🙏", "🔥", "👏", "🤔", "😅", "😍", "🥳", "💯", "✅", "👀", "🙌", "💪", "😎", "🤝", "😬", "🚀", "😴", "🙈", "👌", "😭", "🤯", "💡"]

    @State private var showsMore = false

    var body: some View {
        VStack(spacing: 1) {
            if showsMore {
                moreGrid
            } else {
                if actions.canReact() {
                    reactionRow
                    PalHairline().padding(.vertical, 4).padding(.horizontal, 5)
                }
                MessageMenuRow(title: String(localized: "Reply"), symbol: "arrow.uturn.left", identifier: "contextReply") {
                    dismiss()
                    actions.reply()
                }
                MessageMenuRow(title: String(localized: "Copy"), symbol: "doc.on.doc", identifier: "contextCopy") {
                    Pasteboard.string = actions.text
                    dismiss()
                }
            }
        }
        .frame(width: MessageMenuMetrics.width - 10)
        .modifier(MessageMenuSurface(identifier: "messageContextMenu"))
        #if os(macOS)
        .background {
            Button("", action: dismiss)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        #endif
    }

    private var reactionRow: some View {
        HStack(spacing: 0) {
            ForEach(MessageReactions.choices, id: \.self) { emoji in
                reactionButton(emoji)
            }
            Button { showsMore = true } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: MessageMenuMetrics.glyphSize + 1))
                    .foregroundStyle(PalTokens.textSecondary)
                    .frame(width: MessageMenuMetrics.cellWidth, height: MessageMenuMetrics.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("More reactions"))
            .accessibilityIdentifier("contextMoreReactions")
        }
    }

    private var moreGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 6)
        return LazyVGrid(columns: columns, spacing: 0) {
            ForEach(Self.extras, id: \.self) { emoji in reactionButton(emoji) }
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
                .background(actions.reaction == emoji ? PalTokens.selected : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(emoji))
        .accessibilityIdentifier("contextReaction-\(emoji)")
    }
}

struct MessageMenuRow: View {
    let title: String
    let symbol: String
    let identifier: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: MessageMenuMetrics.glyphSize))
                    .foregroundStyle(PalTokens.textSecondary)
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
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { hovering = $0 }
        #endif
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier(identifier)
    }
}

#if os(iOS)
struct MessageMenuRequest: Identifiable {
    let id = UUID()
    let anchor: CGRect
    let side: MessageSide
    let actions: MessageActions
}

private struct MessageMenuPresenterKey: EnvironmentKey {
    static let defaultValue: (@MainActor (MessageMenuRequest) -> Void)? = nil
}

extension EnvironmentValues {
    var presentMessageMenu: (@MainActor (MessageMenuRequest) -> Void)? {
        get { self[MessageMenuPresenterKey.self] }
        set { self[MessageMenuPresenterKey.self] = newValue }
    }
}

struct MessageMenuHost: View {
    @Binding var request: MessageMenuRequest?

    var body: some View {
        GeometryReader { proxy in
            if let current = request {
                ZStack(alignment: .topLeading) {
                    PalTokens.scrim
                        .opacity(0.55)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { request = nil }
                        .accessibilityHidden(true)
                    MessageMenu(actions: current.actions) { request = nil }
                        .modifier(MessageMenuPlacement(request: current, origin: proxy.frame(in: .global).origin, container: proxy.size))
                }
                .transition(.opacity)
                .accessibilityAddTraits(.isModal)
                .accessibilityAction(.escape) { request = nil }
            }
        }
        .animation(.snappy(duration: 0.16), value: request?.id)
    }
}

private struct MessageMenuPlacement: ViewModifier {
    let request: MessageMenuRequest
    let origin: CGPoint
    let container: CGSize

    @State private var height: CGFloat = 170

    func body(content: Content) -> some View {
        let margin: CGFloat = 12
        let gap: CGFloat = 8
        let width = MessageMenuMetrics.width
        let anchor = request.anchor.offsetBy(dx: -origin.x, dy: -origin.y)
        let preferredX = request.side == .user ? anchor.maxX - width : anchor.minX
        let x = min(max(preferredX, margin), max(margin, container.width - width - margin))
        let below = anchor.maxY + gap
        let fitsBelow = below + height <= container.height - margin
        let preferredY = fitsBelow ? below : anchor.minY - gap - height
        let y = min(max(preferredY, margin), max(margin, container.height - height - margin))
        return content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .offset(x: x, y: y)
    }
}
#endif
