#if os(macOS)
import PalChat
import PalDesign
import SwiftUI

struct MacHTMLViewerHost: View {
    let model: ChatModel

    var body: some View {
        if let session = HTMLViewerCoordinator.shared.session, session.owner == ObjectIdentifier(model) {
            MacHTMLViewer(session: session)
        }
    }
}

private struct MacHTMLViewer: View {
    let session: HTMLViewerSession

    var body: some View {
        ViewerShell(
            title: session.file.name,
            actions: [.openInBrowser, .download, .close],
            disabled: session.pageURL == nil ? [.openInBrowser, .download] : [],
            perform: perform
        ) {
            HTMLViewerBody(session: session)
        } composer: {
            EmptyView()
        }
        .palEscape(.native) { HTMLViewerCoordinator.shared.close() }
    }

    private func perform(_ action: ViewerAction) {
        switch action {
        case .openInBrowser: session.askToOpenPageInBrowser()
        case .download: session.save()
        case .close: HTMLViewerCoordinator.shared.close()
        case .edit: break
        }
    }
}
#endif
