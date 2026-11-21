#if os(macOS)
import PalChat
import PalDesign
import SwiftUI

struct ViewerShell<Content: View, Composer: View>: View {
    let title: String
    let actions: [ViewerAction]
    let disabled: Set<ViewerAction>
    let perform: (ViewerAction) -> Void
    private let content: Content
    private let composer: Composer

    init(
        title: String,
        actions: [ViewerAction],
        disabled: Set<ViewerAction>,
        perform: @escaping (ViewerAction) -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder composer: () -> Composer
    ) {
        self.title = title
        self.actions = actions
        self.disabled = disabled
        self.perform = perform
        self.content = content()
        self.composer = composer()
    }

    private static var titleClearance: CGFloat { 148 }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            composer.padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PalTokens.content.ignoresSafeArea())
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("imageViewer")
    }

    private var topBar: some View {
        ZStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PalTokens.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .palClearGlass(Capsule(), interactive: false)
                .padding(.horizontal, Self.titleClearance)
                .accessibilityIdentifier("imageViewerTitle")
            HStack {
                Spacer(minLength: 0)
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(actions, id: \.self) { action in
                            actionButton(action)
                                .disabled(disabled.contains(action))
                                .opacity(disabled.contains(action) ? 0.35 : 1)
                        }
                    }
                }
            }
            .padding(.trailing, 14)
        }
        .frame(height: 56)
    }

    @ViewBuilder
    private func actionButton(_ action: ViewerAction) -> some View {
        switch action {
        case .edit:
            PalClearGlassIconButton(systemName: "pencil", label: action.label, identifier: action.identifier) { perform(action) }
        case .download:
            PalClearGlassIconButton(systemName: "arrow.down.to.line", label: action.label, identifier: action.identifier) { perform(action) }
        case .close:
            SheetGlassButton(clear: true, escapes: false, accessibilityIdentifier: action.identifier) { perform(action) }
        }
    }
}

extension ViewerAction {
    var label: LocalizedStringKey {
        switch self {
        case .edit: "Edit"
        case .download: "Download"
        case .close: "Close"
        }
    }

    var identifier: String {
        switch self {
        case .edit: "imageViewerEdit"
        case .download: "imageViewerDownload"
        case .close: "imageViewerClose"
        }
    }
}
#endif
