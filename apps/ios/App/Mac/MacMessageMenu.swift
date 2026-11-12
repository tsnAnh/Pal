#if os(macOS)
import PalDesign
import SwiftUI

struct MacMessageMenuRequest: Identifiable {
    let id = UUID()
    let anchor: CGPoint
    let actions: MessageActions
}

struct MacPopupItem: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    let identifier: String
    let action: () -> Void
}

struct MacAttachMenuRequest: Identifiable {
    let id = UUID()
    let anchor: CGPoint
    let items: [MacPopupItem]
}

struct MacMessageMenuHost: View {
    @Environment(MacShell.self) private var shell

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            if let request = shell.messageMenu {
                popup(anchor: request.anchor, origin: origin, size: proxy.size, above: false, dismiss: { shell.messageMenu = nil }) {
                    MessageMenu(actions: request.actions, dismiss: { shell.messageMenu = nil })
                }
                .id(request.id)
            } else if let request = shell.attachMenu {
                popup(anchor: request.anchor, origin: origin, size: proxy.size, above: true, dismiss: { shell.attachMenu = nil }) {
                    MacActionMenu(items: request.items, identifier: "attachMenu", dismiss: { shell.attachMenu = nil })
                }
                .id(request.id)
            }
        }
        .animation(.snappy(duration: 0.14), value: shell.messageMenu?.id)
        .animation(.snappy(duration: 0.14), value: shell.attachMenu?.id)
    }

    private func popup<Content: View>(anchor: CGPoint, origin: CGPoint, size: CGSize, above: Bool, dismiss: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
                .accessibilityHidden(true)
            content()
                .modifier(MacMessageMenuPlacement(anchor: CGPoint(x: anchor.x - origin.x, y: anchor.y - origin.y), container: size, above: above))
        }
        .transition(.scale(scale: 0.97, anchor: above ? .bottomLeading : .topLeading).combined(with: .opacity))
    }
}

private struct MacMessageMenuPlacement: ViewModifier {
    let anchor: CGPoint
    let container: CGSize
    let above: Bool

    @State private var size = CGSize(width: MessageMenuMetrics.width, height: 128)

    func body(content: Content) -> some View {
        let margin: CGFloat = 8
        let x = min(max(anchor.x, margin), container.width - size.width - margin)
        let y: CGFloat
        if above {
            y = max(margin, anchor.y - size.height)
        } else {
            y = anchor.y + size.height + margin <= container.height ? anchor.y : max(margin, anchor.y - size.height)
        }
        return content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .offset(x: x, y: y)
    }
}

private struct MacActionMenu: View {
    let items: [MacPopupItem]
    let identifier: String
    let dismiss: () -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    var body: some View {
        VStack(spacing: 1) {
            ForEach(items) { item in
                MessageMenuRow(title: item.title, symbol: item.symbol, identifier: item.identifier) {
                    dismiss()
                    item.action()
                }
            }
        }
        .padding(5)
        .frame(width: 184)
        .palGlass(shape, interactive: false)
        .overlay(shape.strokeBorder(PalTokens.panelBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
        .background {
            Button("", action: dismiss)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}
#endif
