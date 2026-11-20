#if os(iOS)
import PalConnect
import PalDesign
import SwiftUI

struct ConnectAppsPhoneBar<Leading: View, Trailing: View>: View {
    let title: String
    private let leading: Leading
    private let trailing: Trailing

    @Environment(\.hermesTheme) private var theme

    init(title: String, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                leading
                Text(title)
                    .hermesText(.sheetTitle)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                trailing
            }
        }
        .padding(.horizontal, PalMetrics.screenMargin)
        .padding(.top, PalMetrics.sheetHeaderTopPadding)
        .padding(.bottom, 12)
    }
}

struct ConnectAppsPhoneHeader: View {
    @Bindable var model: ConnectAppsModel
    let close: () -> Void

    var body: some View {
        let connected = model.macState.installed.count
        ConnectAppsPhoneBar(
            title: String(localized: "Connect apps"),
            leading: { PalClearGlassIconButton(systemName: "xmark", label: "Close", identifier: "connectApps-close", action: close) },
            trailing: { if connected > 0 { installedButton(connected) } }
        )
    }

    private func installedButton(_ count: Int) -> some View {
        Button { model.showInstalled() } label: { Text("\(count) connected") }
            .buttonStyle(PalClearCapsuleStyle(height: 30, horizontalPadding: 12))
            .accessibilityLabel(Text("\(count) connected, opens manage"))
            .accessibilityIdentifier("connectAppsInstalledButton")
    }
}

struct ConnectAppsPhoneRoot: View {
    @Bindable var model: ConnectAppsModel
    let close: () -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        let surface = Color(theme.palette.sheetBackground)
        VStack(spacing: 0) {
            switch model.navigation.screen {
            case .apps:
                ConnectAppsPhoneHeader(model: model, close: close)
                ConnectAppsList(model: model)
            case .installed:
                ConnectAppsPhoneInstalled(model: model, close: close)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(surface.ignoresSafeArea())
        .presentationBackground(surface)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectApps")
    }
}
#endif
