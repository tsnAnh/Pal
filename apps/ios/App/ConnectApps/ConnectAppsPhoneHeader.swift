#if os(iOS)
import PalConnect
import PalDesign
import SwiftUI
import UIKit

struct ConnectAppsPhoneRoot: View {
    @Bindable var model: ConnectAppsModel
    let close: () -> Void

    @Environment(\.hermesTheme) private var theme
    @State private var shownConnector: CustomConnectorModel?

    private var showsInstalled: Binding<Bool> {
        Binding(
            get: { model.navigation.screen == .installed },
            set: { if !$0 { model.leaveInstalled() } }
        )
    }

    private var showsCustomConnector: Binding<Bool> {
        Binding(
            get: { model.customConnector != nil },
            set: { if !$0, model.customConnector != nil { Task { await model.leaveCustomConnector() } } }
        )
    }

    var body: some View {
        NavigationStack {
            SheetChrome(
                title: String(localized: "Connect apps"),
                accessibilityIdentifier: "connectApps",
                leadingAccessibilityIdentifier: "connectApps-close",
                onLeading: close,
                trailing: { installedButton(model.macState.installed.count) },
                content: { ConnectAppsList(model: model) }
            )
            .environment(\.sheetChromeHostedInNavigation, true)
            .connectorDetailsDestination(model, origin: .root)
            .navigationDestination(isPresented: showsInstalled) {
                ConnectAppsPhoneInstalled(model: model)
                    .environment(\.sheetChromeHostedInNavigation, true)
            }
            .navigationDestination(isPresented: showsCustomConnector) {
                if let connector = model.customConnector ?? shownConnector {
                    SheetChrome(
                        leading: .back,
                        accessibilityIdentifier: "customConnectorScreen",
                        onLeading: { Task { await model.leaveCustomConnector() } },
                        content: {
                            CustomConnectorForm(model: connector, style: .phone(theme)) { Task { await model.leaveCustomConnector() } }
                        }
                    )
                    .environment(\.sheetChromeHostedInNavigation, true)
                }
            }
        }
        .tint(.primary)
        .onChange(of: model.customConnector?.id, initial: true) {
            if let connector = model.customConnector { shownConnector = connector }
        }
        .onChange(of: model.navigation.screen) { dismissKeyboard() }
        .onChange(of: model.customConnector?.id) { dismissKeyboard() }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    @ViewBuilder
    private func installedButton(_ count: Int) -> some View {
        if count > 0 {
            Button { model.showInstalled() } label: { Text("\(count) connected") }
                .accessibilityLabel(Text("\(count) connected, opens manage"))
                .accessibilityIdentifier("connectAppsInstalledButton")
        }
    }
}
#endif
