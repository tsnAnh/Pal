#if os(iOS)
import PalConnect
import PalDesign
import SwiftUI

struct ConnectAppsPhoneInstalled: View {
    @Bindable var model: ConnectAppsModel

    var body: some View {
        let state = model.macState
        SheetChrome(
            title: String(localized: "Connected"),
            leading: .back,
            accessibilityIdentifier: "connectAppsInstalled",
            leadingAccessibilityIdentifier: "connectAppsInstalledBack",
            onLeading: { model.leaveInstalled() },
            content: {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ConnectFlatSectionHeader(title: String(localized: "Connected"), identifier: "connectAppsInstalledTitle")
                        ConnectFlatRows(state.installed) { installedRow($0) }
                        if !state.privateSkills.isEmpty { privateSkills(state.privateSkills) }
                    }
                    .padding(.bottom, PalMetrics.cardGap)
                }
                .scrollIndicators(.automatic)
            }
        )
        .connectorDetailsDestination(model, origin: .installed)
    }

    private func installedRow(_ item: ConnectInstalledItem) -> some View {
        let app = item.app.flatMap { $0.opensDetails ? $0 : nil }
        return ConnectFlatRow(
            title: item.name, subtitle: item.subtitle, identifier: "connectInstalled-\(item.id)",
            open: app.map { target in { model.openDetails(target) } }, opensWholeRow: app != nil,
            icon: { ConnectInstalledIcon(item: item) },
            trailing: {
                if app != nil { ConnectOpenMark(state: .connected) } else { ConnectConnectedMark() }
            }
        )
    }

    private func privateSkills(_ skills: [InstalledSkill]) -> some View {
        Group {
            ConnectFlatSectionHeader(title: String(localized: "Private skills"), identifier: "connectAppsPrivateSkillsTitle")
            ConnectFlatRows(skills) { skill in
                ConnectFlatRow(
                    title: skill.name,
                    subtitle: skill.description.isEmpty
                        ? String(localized: "Created locally") : String(localized: "Created locally · \(skill.description)"),
                    identifier: "connectPrivateSkill-\(skill.id)",
                    icon: { PluginGlyphTile() },
                    trailing: { EmptyView() }
                )
            }
        }
    }
}
#endif
