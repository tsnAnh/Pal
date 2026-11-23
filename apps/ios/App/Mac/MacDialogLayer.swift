#if os(macOS)
import PalDesign
import SwiftUI

struct MacDialogLayer: View {
    let center: MacDialogCenter
    let window: CGSize

    var body: some View {
        ZStack {
            if let request = center.current {
                MacModalScrim {}
                MacDialogPanel(request: request, window: window)
                    .id(request.id)
            }
        }
        .animation(.snappy(duration: 0.18), value: center.current?.id)
    }
}

private struct MacDialogPanel: View {
    let request: MacDialogRequest
    let window: CGSize

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    var body: some View {
        let cap = MacModalSizing.frame(window: window)
        let measured = cap.width > 0 && cap.height > 0
        ViewThatFits(in: .vertical) {
            stack(request.content, scrolls: false)
            stack(request.content, scrolls: true)
        }
        .frame(minWidth: MacModalSizing.alertMinWidth, maxWidth: measured ? cap.width : nil, maxHeight: measured ? cap.height : nil)
        .background(PalTokens.content, in: shape)
        .overlay(shape.strokeBorder(PalTokens.panelBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 12)
        .background { returnKey }
        .palEscape(.dialog) { request.press(.escape) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("macDialog")
        .transition(.scale(scale: 0.97).combined(with: .opacity))
    }

    private func stack(_ content: MacDialogContent, scrolls: Bool) -> some View {
        VStack(spacing: 14) {
            Text(content.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(PalTokens.textPrimary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: MacModalSizing.alertTextWidth)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("macDialogTitle")
            if let message = content.message {
                messageView(message, scrolls: scrolls)
            }
            if let checkbox = content.checkbox {
                MacDialogCheckboxRow(checkbox: checkbox)
            }
            HStack(spacing: 10) {
                ForEach(content.displayOrder) { action in button(action) }
            }
            .padding(.top, 8)
        }
        .padding(24)
    }

    @ViewBuilder
    private func messageView(_ message: String, scrolls: Bool) -> some View {
        let text = Text(message)
            .font(.system(size: 13))
            .foregroundStyle(PalTokens.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: MacModalSizing.alertTextWidth)
            .accessibilityIdentifier("macDialogMessage")
        if scrolls {
            ScrollView { text }.scrollBounceBehavior(.basedOnSize)
        } else {
            text.fixedSize(horizontal: false, vertical: true)
        }
    }

    private func button(_ action: MacDialogAction) -> some View {
        Button(action.title, role: action.role == .destructive ? .destructive : nil) { request.activate(action) }
            .glassButtonStyle()
            .accessibilityIdentifier(action.identifier ?? "macDialogAction-\(action.title)")
    }

    private var returnKey: some View {
        Button("") { request.press(.returnKey) }
            .keyboardShortcut(.defaultAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}

private struct MacDialogCheckboxRow: View {
    @Bindable var checkbox: MacDialogCheckbox

    var body: some View {
        Toggle(isOn: $checkbox.isOn) {
            Text(checkbox.title)
                .font(.system(size: 13))
                .foregroundStyle(PalTokens.textPrimary)
        }
        .toggleStyle(.checkbox)
        .accessibilityIdentifier(checkbox.identifier)
    }
}
#endif
