#if os(macOS)
import PalConnect
import PalDesign
import PalDevice
import PalDiagnostics
import PalProtocol
import SwiftUI

extension ConnectAppsList {
    var macBody: some View {
        let _ = PalPerf.event("connect.body.main") // swiftlint:disable:this redundant_discardable_let
        let state = model.macState
        return VStack(spacing: 0) {
            ClearGlassSearchField(
                text: $model.query, prompt: String(localized: "Search across apps and skills"),
                accessibilityLabel: String(localized: "Search apps and skills"), accessibilityIdentifier: "connectAppsSearch"
            )
            .padding(.horizontal, PalMetrics.screenMargin)
            .padding(.bottom, PalMetrics.captionToCardGap)
            ConnectAppsMacChips(model: model, bar: state.chips)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    resumeBanner
                    macContent(state)
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
        }
    }

    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: 18, alignment: .top), GridItem(.flexible(), spacing: 18, alignment: .top)]
    }

    @ViewBuilder
    private func macContent(_ state: ConnectMacState) -> some View {
        switch model.phase {
        case .loading where model.catalog.apps.isEmpty:
            DelayedProgressView().frame(maxWidth: .infinity).padding(.top, PalMetrics.cardGap).accessibilityIdentifier("connectAppsLoading")
        case .unavailable:
            StatusBlock(status: SetupStatus(code: "offline"), identifierPrefix: "connectAppsUnavailable") { Task { await model.reload() } }
                .padding(.top, PalMetrics.cardGap)
        default:
            macLoaded(state)
        }
    }

    @ViewBuilder
    private func macLoaded(_ state: ConnectMacState) -> some View {
        let _ = model.noteListRendered() // swiftlint:disable:this redundant_discardable_let
        let searching = !model.trimmedQuery.isEmpty
        if !searching { legacySection }
        ForEach(state.sections) { group in macSection(group, deviceRows: state.deviceRows) }
        if searching {
            if state.sections.isEmpty, state.skills.isEmpty {
                macEmpty
            } else if !state.skills.isEmpty {
                skillResults(state.skills)
            }
        } else {
            SkillsCatalogEntry { model.showsSkills = true }
            capabilitiesSection
        }
    }

    private var macEmpty: some View {
        VStack(spacing: 4) {
            Text("No apps match “\(model.trimmedQuery)”.")
                .font(.system(size: 14))
            Text("Try another word, or add a custom connector below.")
                .font(.system(size: 12))
        }
        .foregroundStyle(PalTokens.textSecondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connectAppsNoMatches")
    }

    private func macSection(_ group: ConnectMacSectionEntries, deviceRows: [DeviceConnectorRow]) -> some View {
        let section = group.section
        let expanded = model.isExpanded(section)
        let count = section.visibleCount(expanded: expanded)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(section.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PalTokens.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(macIdentifier(section))
                Spacer()
                if section.hasViewAll {
                    Button(expanded ? String(localized: "Show fewer") : String(localized: "View all")) { model.toggleExpanded(section) }
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(PalTokens.textSecondary)
                        .accessibilityIdentifier("connectAppsViewAll-\(section.id)")
                }
            }
            .padding(.horizontal, 2)
            GlassEffectContainer(spacing: 8) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                    if section.kind == .thisDevice {
                        ForEach(deviceRows.prefix(count)) { macDeviceRow($0) }
                    } else {
                        ForEach(group.entries.prefix(count)) { macRow($0) }
                    }
                }
            }
        }
        .padding(.top, 14)
        .padding(.horizontal, PalMetrics.screenMargin)
    }

    private func macIdentifier(_ section: ConnectMacSection) -> String {
        switch section.kind {
        case .needsAttention: "connectAppsSection-attention"
        case .thisDevice: "connectAppsSection-device-this-device"
        case .category(let name): "connectAppsSection-\(name)"
        case .results: "connectAppsSection-results"
        }
    }

    private func macRow(_ entry: ConnectListEntry) -> some View {
        ConnectMacRow(
            title: entry.row.name, subtitle: entry.row.summary, problem: entry.row.hasProblem, identifier: "connectApp-\(entry.app.id)",
            icon: { ConnectorLogoTile(app: entry.app) },
            trailing: {
                ConnectCapsule(state: entry.row.state, identifier: "connectApp-\(entry.app.id)-action") {
                    model.performRowAction(entry.app, state: entry.row.state)
                }
            }
        )
    }

    private func macDeviceRow(_ row: DeviceConnectorRow) -> some View {
        let look = DeviceRowPresentation(row: row)
        let identifier = "deviceConnector-\(row.id.rawValue)"
        return ConnectMacRow(
            title: row.entry.title, subtitle: look.summary, problem: false, identifier: identifier,
            icon: { DeviceTile(connector: row.id) },
            trailing: { macDeviceTrailing(look, id: row.id, identifier: identifier) }
        )
    }

    @ViewBuilder
    private func macDeviceTrailing(_ look: DeviceRowPresentation, id: DeviceConnectorID, identifier: String) -> some View {
        if model.devices.busy.contains(id) {
            ProgressView().controlSize(.small)
        } else if let title = look.buttonTitle {
            let localized = String(localized: String.LocalizationValue(title))
            switch look.action {
            case .allow:
                Button(localized) { Task { await model.devices.allow(id) } }
                    .buttonStyle(.palClearCapsule)
                    .accessibilityIdentifier("\(identifier)-action")
            case .openSettings:
                Button(localized) { model.devices.openSettings(for: id) }
                    .buttonStyle(.palClearCapsule)
                    .accessibilityIdentifier("\(identifier)-action")
            case nil:
                EmptyView()
            }
        }
    }
}

struct ConnectMacRow<Icon: View, Trailing: View>: View {
    let title: String
    let subtitle: String
    let problem: Bool
    let identifier: String
    private let icon: Icon
    private let trailing: Trailing

    init(
        title: String, subtitle: String, problem: Bool, identifier: String,
        @ViewBuilder icon: () -> Icon, @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.problem = problem
        self.identifier = identifier
        self.icon = icon()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PalTokens.textPrimary)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(problem ? Color.red : PalTokens.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            trailing
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

struct ConnectCapsule: View {
    let state: ConnectRowState
    let identifier: String
    let perform: () -> Void

    var body: some View {
        switch state {
        case .connect, .setUp, .needsAttention, .connected:
            Button(action: perform) { Text(verbatim: state.actionTitle ?? "") }
                .buttonStyle(.palClearCapsule)
                .opacity(state == .connected ? 0.7 : 1)
                .accessibilityIdentifier(identifier)
        case .waiting:
            Button {} label: {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Connecting")
                }
            }
            .buttonStyle(.palClearCapsule)
            .disabled(true)
            .accessibilityIdentifier(identifier)
        case .unavailable:
            EmptyView()
        }
    }
}

struct ConnectAppsMacChips: View {
    @Bindable var model: ConnectAppsModel
    let bar: ConnectChipBar

    private var isSearching: Bool { !model.trimmedQuery.isEmpty }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                chip(String(localized: "All"), .all, identifier: "all")
                chip(model.devices.thisDevice.title, .thisDevice, identifier: "device")
                ForEach(bar.leading, id: \.self) { name in chip(name, .category(name), identifier: name) }
                if !bar.more.isEmpty { moreMenu }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, PalMetrics.screenMargin)
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectAppsChips")
    }

    private func isSelected(_ value: ConnectChip) -> Bool { !isSearching && model.chip == value }

    private func chip(_ title: String, _ value: ConnectChip, identifier: String) -> some View {
        Button { model.selectChip(value) } label: { Text(title) }
            .buttonStyle(.palClearChip(selected: isSelected(value)))
            .accessibilityAddTraits(isSelected(value) ? .isSelected : [])
            .accessibilityIdentifier("connectAppsChip-\(identifier)")
    }

    private var moreSelected: Bool { !isSearching && bar.moreIsSelected(model.chip) }

    private var moreTitle: String {
        if moreSelected, case .category(let name) = model.chip { name } else { String(localized: "More") }
    }

    private var moreMenu: some View {
        Menu {
            ForEach(bar.more, id: \.self) { name in
                Button(name) { model.selectChip(.category(name)) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(moreTitle)
                PalIcon("chevron.down").font(.system(size: 9, weight: .semibold))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.palClearChip(selected: moreSelected))
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("connectAppsChip-more")
    }
}
#endif
