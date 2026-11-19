#if os(macOS)
import PalConnect
import PalDesign
import PalDiagnostics
import SwiftUI

struct ConnectAppsMacHeader: View {
    @Bindable var model: ConnectAppsModel

    var body: some View {
        let installed = model.macState.installed
        HStack {
            Text("Connect Apps")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(PalTokens.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .padding(.leading, PalMetrics.macPanelTitleClearance)
            Spacer()
            if !installed.isEmpty { installedButton(installed) }
        }
        .padding(.horizontal, PalMetrics.cardGap)
        .frame(height: MacMetrics.topBarHeight)
    }

    private func installedButton(_ installed: [ConnectInstalledItem]) -> some View {
        Button { model.showInstalled() } label: {
            HStack(spacing: 8) {
                HStack(spacing: -7) {
                    ForEach(installed.prefix(3)) { item in
                        ConnectInstalledIcon(item: item).scaleEffect(0.5).frame(width: 20, height: 20)
                    }
                }
                Text("\(installed.count) connected")
                PalIcon("chevron.down").font(.system(size: 9, weight: .semibold))
            }
        }
        .buttonStyle(PalClearCapsuleStyle(height: 34, horizontalPadding: 12, weight: .regular))
        .accessibilityIdentifier("connectAppsInstalledButton")
    }
}

struct ConnectInstalledIcon: View {
    let item: ConnectInstalledItem

    var body: some View {
        switch item.source {
        case .app(let app): ConnectorLogoTile(app: app)
        case .device(let id): DeviceTile(connector: id)
        }
    }
}

struct ConnectAppsMacInstalled: View {
    @Bindable var model: ConnectAppsModel

    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: 18, alignment: .top), GridItem(.flexible(), spacing: 18, alignment: .top)]
    }

    var body: some View {
        let installed = model.macState.installed
        let count = ConnectMacLayout.visibleCount(total: installed.count, expanded: model.showsAllInstalled)
        VStack(spacing: 0) {
            HStack {
                Text("Connect Apps")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(PalTokens.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.leading, PalMetrics.macPanelTitleClearance)
                Spacer()
            }
            .padding(.horizontal, PalMetrics.cardGap)
            .frame(height: MacMetrics.topBarHeight)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("Manage plugins and skills")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(PalTokens.textPrimary)
                        .padding(.top, 10)
                        .padding(.horizontal, PalMetrics.screenMargin + 2)
                        .accessibilityAddTraits(.isHeader)
                    Text("Installed")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(PalTokens.textPrimary)
                        .padding(.top, 14)
                        .padding(.horizontal, PalMetrics.screenMargin + 2)
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                        ForEach(installed.prefix(count)) { item in installedRow(item) }
                    }
                    .padding(.horizontal, PalMetrics.screenMargin)
                    if installed.count > ConnectMacLayout.collapsedRowLimit {
                        Button(model.showsAllInstalled ? String(localized: "Show fewer") : String(localized: "Show all \(installed.count) plugins")) {
                            model.showsAllInstalled.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(PalTokens.textSecondary)
                        .padding(.top, 8)
                        .padding(.horizontal, PalMetrics.screenMargin + 6)
                        .accessibilityIdentifier("connectAppsInstalledShowAll")
                    }
                }
                .padding(.bottom, PalMetrics.cardGap)
            }
            .scrollIndicators(.automatic)
        }
        .overlay(alignment: .topLeading) {
            SheetGlassButton(leading: .back, clear: true, accessibilityIdentifier: "connectAppsInstalledBack") { model.leaveInstalled() }
                .padding(.top, PalMetrics.macPanelCloseTopInset)
                .padding(.leading, PalMetrics.macPanelCloseLeadingInset)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectAppsInstalled")
    }

    private func installedRow(_ item: ConnectInstalledItem) -> some View {
        ConnectMacRow(
            title: item.name, subtitle: item.countLine, problem: false, identifier: "connectInstalled-\(item.id)",
            icon: { ConnectInstalledIcon(item: item) },
            trailing: {
                Text("Connected")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.green)
                    .lineLimit(1)
                    .fixedSize()
            }
        )
    }
}
#endif
