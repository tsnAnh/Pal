#if os(iOS)
import PalConnect
import PalDesign
import SwiftUI

struct ConnectAppsPhoneInstalled: View {
    @Bindable var model: ConnectAppsModel
    let close: () -> Void

    var body: some View {
        let state = model.macState
        VStack(spacing: 0) {
            ConnectAppsPhoneBar(
                title: String(localized: "Connected"),
                leading: {
                    PalClearGlassIconButton(
                        systemName: "chevron.left", label: "Back", identifier: "connectAppsInstalledBack", action: { model.leaveInstalled() }
                    )
                },
                trailing: {
                    PalClearGlassIconButton(systemName: "xmark", label: "Close", identifier: "connectAppsInstalledClose", action: close)
                }
            )
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectAppsInstalled")
    }

    private func installedRow(_ item: ConnectInstalledItem) -> some View {
        ConnectFlatRow(
            title: item.name, subtitle: item.countLine, identifier: "connectInstalled-\(item.id)",
            icon: { ConnectInstalledIcon(item: item) },
            trailing: { ConnectConnectedMark() }
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
