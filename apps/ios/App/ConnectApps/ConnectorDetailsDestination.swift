#if os(iOS)
import PalDesign
import SwiftUI

private struct ConnectorDetailsDestination: ViewModifier {
    @Bindable var model: ConnectAppsModel
    let origin: ConnectorDetailsOrigin

    private var route: Binding<ConnectorDetailsRoute?> {
        switch origin {
        case .root: $model.rootDetails
        case .installed: $model.installedDetails
        }
    }

    func body(content: Content) -> some View {
        content
            .navigationDestination(item: route) { route in
                if let details = model.detailsModel(appID: route.appID) {
                    ConnectorDetailsScreen(model: details) { model.closeDetails() }
                        .environment(\.sheetChromeHostedInNavigation, true)
                }
            }
            .onChange(of: route.wrappedValue) { model.releaseUnusedDetailsModels() }
    }
}

extension View {
    func connectorDetailsDestination(_ model: ConnectAppsModel, origin: ConnectorDetailsOrigin) -> some View {
        modifier(ConnectorDetailsDestination(model: model, origin: origin))
    }
}
#endif
