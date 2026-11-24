#if os(iOS)
import PalDesign
import SwiftUI

struct HTMLViewerCover: View {
    let session: HTMLViewerSession
    let close: () -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        NavigationStack {
            HTMLViewerBody(session: session)
                .background(Color(theme.palette.canvas))
                .navigationTitle(session.file.name)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        PalCloseButton(action: close)
                            .accessibilityIdentifier("htmlViewerClose")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { session.save() } label: { Label("Save", palIcon: "square.and.arrow.up") }
                            .disabled(session.pageURL == nil)
                            .accessibilityIdentifier("htmlViewerSave")
                    }
                }
                .toolbarTitleDisplayMode(.inline)
        }
    }
}
#endif
