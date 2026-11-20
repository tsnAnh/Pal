#if os(macOS)
import PalDesign
import SwiftUI

struct MacSheetLayer: View {
    let center: MacSheetCenter

    var body: some View {
        ZStack {
            ForEach(center.stack) { request in
                let isTop = request.id == center.stack.last?.id
                MacModalScrim {}
                MacModalPanel(
                    identifier: "macSheet", closeIdentifier: "macSheetClose", close: request.dismiss,
                    content: {
                        request.content()
                            .preference(key: MacPanelCloseKey.self, value: MacPanelCloseOverride(hidden: true))
                            .background { if isTop { escapeKey(request) } }
                    }
                )
            }
        }
        .animation(.snappy(duration: 0.2), value: center.stack.map(\.id))
    }

    private func escapeKey(_ request: MacSheetRequest) -> some View {
        Button("") { request.dismiss() }
            .keyboardShortcut(.cancelAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}
#endif
