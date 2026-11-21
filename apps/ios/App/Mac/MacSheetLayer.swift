#if os(macOS)
import PalDesign
import SwiftUI

struct MacSheetLayer: View {
    let center: MacSheetCenter

    var body: some View {
        ZStack {
            ForEach(center.stack) { request in
                MacSheetPanel(request: request, isTop: request.id == center.stack.last?.id)
            }
        }
        .animation(.snappy(duration: 0.2), value: center.stack.map(\.id))
    }
}

private struct MacSheetPanel: View {
    let request: MacSheetRequest
    let isTop: Bool

    @State private var dismissLocked = false

    var body: some View {
        MacModalScrim {}
        MacModalPanel(
            identifier: "macSheet", closeIdentifier: "macSheetClose", close: request.dismiss,
            content: {
                request.content()
                    .frame(maxWidth: request.readable ? MacModalSizing.readableColumn : .infinity, maxHeight: .infinity)
                    .environment(\.sheetClose, request.dismiss)
                    .preference(key: MacPanelCloseKey.self, value: MacPanelCloseOverride(hidden: true))
                    .onPreferenceChange(MacSheetDismissLockKey.self) { dismissLocked = $0 }
                    .background { if isTop, !dismissLocked { escapeKey } }
            }
        )
    }

    private var escapeKey: some View {
        Button("") { request.dismiss() }
            .keyboardShortcut(.cancelAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}
#endif
