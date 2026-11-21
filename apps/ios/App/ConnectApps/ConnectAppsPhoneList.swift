#if os(iOS)
import PalConnect
import PalDesign
import PalDevice
import PalDiagnostics
import PalProtocol
import SwiftUI

extension ConnectAppsList {
    var phoneBody: some View {
        let _ = PalPerf.event("connect.body.main") // swiftlint:disable:this redundant_discardable_let
        let state = model.macState
        return VStack(spacing: 0) {
            ConnectAppsChips(model: model, bar: state.chips)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    resumeBanner
                    content { phoneLoaded(state) }
                    Button { model.addCustomConnector() } label: {
                        Label("Add a custom connector", palIcon: "plus")
                    }
                    .buttonStyle(.palClearWide)
                    .accessibilityIdentifier("addCustomConnectorButton")
                    .padding(.top, PalMetrics.cardGap)
                    .padding(.horizontal, PalMetrics.screenMargin)
                }
                .padding(.bottom, PalMetrics.cardGap)
            }
            .scrollIndicators(.automatic)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { phoneSearch }
        }
    }

    private var phoneSearch: some View {
        GlassEffectContainer {
            ClearGlassSearchField(
                text: $model.query, prompt: String(localized: "Search across apps and skills"),
                accessibilityLabel: String(localized: "Search apps and skills"), accessibilityIdentifier: "connectAppsSearch",
                height: 46, fontSize: 15
            )
        }
        .shadow(color: Color.black.opacity(0.16), radius: 14, y: 4)
        .padding(.horizontal, PalMetrics.screenMargin)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func phoneLoaded(_ state: ConnectMacState) -> some View {
        let _ = model.noteListRendered() // swiftlint:disable:this redundant_discardable_let
        let searching = !model.trimmedQuery.isEmpty
        ForEach(state.sections) { group in phoneSection(group, deviceRows: state.deviceRows) }
        if searching {
            if state.sections.isEmpty, state.skills.isEmpty {
                phoneEmpty
            } else if !state.skills.isEmpty {
                skillResults(state.skills)
            }
        } else {
            SkillsCatalogEntry { model.showsSkills = true }
            capabilitiesSection
        }
    }

    private var phoneEmpty: some View {
        VStack(spacing: 6) {
            PalIcon("magnifyingglass", ink: .tertiary)
                .font(.system(size: 30))
                .padding(.bottom, 4)
            Text("No results for “\(model.trimmedQuery)”")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PalTokens.textPrimary)
            Text("Try another name or clear the search.")
                .font(.system(size: 12))
                .foregroundStyle(PalTokens.textSecondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
        .padding(.horizontal, PalMetrics.screenMargin)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connectAppsNoMatches")
    }

    private func phoneSection(_ group: ConnectMacSectionEntries, deviceRows: [DeviceConnectorRow]) -> some View {
        let section = group.section
        let open: (() -> Void)? = section.kind.chip == nil ? nil : { model.showSection(section) }
        return VStack(alignment: .leading, spacing: 0) {
            ConnectFlatSectionHeader(title: section.title, identifier: section.identifier, action: open)
            if section.kind == .thisDevice {
                rowBlock(deviceRows) { phoneDeviceRow($0) }
            } else {
                rowBlock(group.entries) { phoneAppRow($0) }
            }
        }
    }

    private func phoneAppRow(_ entry: ConnectListEntry) -> some View {
        let opens = entry.app.opensDetails
        let wholeRow = opens && entry.row.state.showsOpenMark
        return ConnectFlatRow(
            title: entry.row.name, subtitle: entry.row.summary, problem: entry.row.hasProblem, identifier: "connectApp-\(entry.app.id)",
            open: opens ? { model.openDetails(entry.app) } : nil, opensWholeRow: wholeRow,
            icon: { ConnectorLogoTile(app: entry.app) },
            trailing: {
                if wholeRow {
                    ConnectOpenMark(state: entry.row.state)
                } else {
                    ConnectCapsule(state: entry.row.state, identifier: "connectApp-\(entry.app.id)-action", quiet: true) {
                        model.performRowAction(entry.app, state: entry.row.state)
                    }
                }
            }
        )
    }

    private func phoneDeviceRow(_ row: DeviceConnectorRow) -> some View {
        let look = DeviceRowPresentation(row: row)
        let identifier = "deviceConnector-\(row.id.rawValue)"
        return ConnectFlatRow(
            title: row.entry.title, subtitle: look.summary, identifier: identifier,
            icon: { DeviceTile(connector: row.id) },
            trailing: { phoneDeviceTrailing(look, id: row.id, identifier: identifier) }
        )
    }

    @ViewBuilder
    private func phoneDeviceTrailing(_ look: DeviceRowPresentation, id: DeviceConnectorID, identifier: String) -> some View {
        if model.devices.busy.contains(id) {
            ProgressView().controlSize(.small)
        } else if let title = look.buttonTitle {
            let localized = String(localized: String.LocalizationValue(title))
            switch look.action {
            case .allow:
                Button(localized) { Task { await model.devices.allow(id) } }
                    .buttonStyle(PalClearCapsuleStyle(height: 30, horizontalPadding: 14))
                    .accessibilityIdentifier("\(identifier)-action")
            case .openSettings:
                Button(localized) { model.devices.openSettings(for: id) }
                    .buttonStyle(PalClearCapsuleStyle(height: 30, horizontalPadding: 14))
                    .accessibilityIdentifier("\(identifier)-action")
            case nil:
                EmptyView()
            }
        }
    }
}
#endif
