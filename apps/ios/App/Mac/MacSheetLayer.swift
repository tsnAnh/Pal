#if os(macOS)
import PalDesign
import SwiftUI

struct MacSheetLayer: View {
    let center: MacSheetCenter

    var body: some View {
        ZStack {
            ForEach(center.stack) { request in
                MacSheetPanel(request: request)
            }
        }
        .animation(.snappy(duration: 0.2), value: center.stack.map(\.id))
    }
}

private struct MacSheetPanel: View {
    let request: MacSheetRequest

    var body: some View {
        MacModalScrim {}
        MacModalPanel(
            size: request.size, layer: .sheet, identifier: "macSheet", closeIdentifier: "macSheetClose", close: request.dismiss,
            content: {
                request.content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environment(\.sheetClose, request.dismiss)
                    .preference(key: MacPanelCloseKey.self, value: MacPanelCloseOverride(hidden: true))
            }
        )
    }
}
#endif
