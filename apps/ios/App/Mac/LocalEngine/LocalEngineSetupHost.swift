#if os(macOS)
import PalDesign
import SwiftUI

struct LocalEngineSetupHost: View {
    let engine: LocalEngineModel

    @State private var windowSize = MacWindowSize()

    var body: some View {
        ZStack {
            if engine.isPresentingSetup {
                MacModalScrim { engine.dismissSetup() }
                MacModalPanel(
                    size: .full,
                    closeDisabled: engine.isInstalling || engine.isSigningIn,
                    identifier: "localEngineSetupPanel",
                    closeIdentifier: "localEngineSetupClose",
                    close: { engine.dismissSetup() },
                    content: { LocalEngineSetupPanel(engine: engine) }
                )
                .background { escapeKey }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self, of: \.size) { windowSize.update($0) }
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.macWindowSize, windowSize)
        .animation(.snappy(duration: 0.2), value: engine.isPresentingSetup)
    }

    @ViewBuilder
    private var escapeKey: some View {
        if !engine.isInstalling, !engine.isSigningIn {
            Button("") { engine.dismissSetup() }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}
#endif
