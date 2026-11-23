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
                    layer: .stepFlow,
                    identifier: "localEngineSetupPanel",
                    closeIdentifier: "localEngineSetupClose",
                    close: { engine.dismissSetup() },
                    content: {
                        LocalEngineSetupPanel(engine: engine)
                            .palEscapePolicy(EscapePolicy(blocking: .inFlight, when: engine.isInstalling || engine.isSigningIn || engine.providerSignInBusy))
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self, of: \.size) { windowSize.update($0) }
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.macWindowSize, windowSize)
        .animation(.snappy(duration: 0.2), value: engine.isPresentingSetup)
    }
}
#endif
