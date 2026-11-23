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
            ConnectAppsChips(model: model, bar: state.chips)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    resumeBanner
                    macContent(state)
                    Button { model.addCustomConnector() } label: {
                        Label("Add a custom connector", palIcon: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .glassButtonStyle()
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
        let panelWidth = MacModalSizing.sheetSize(window: windowSize?.size ?? .zero).width
        let count = MacModalSizing.gridColumns(panelWidth: panelWidth)
        return Array(repeating: GridItem(.flexible(), spacing: 18, alignment: .top), count: count)
    }

    private func macContent(_ state: ConnectMacState) -> some View {
        content { macLoaded(state) }
    }

    @ViewBuilder
    private func macLoaded(_ state: ConnectMacState) -> some View {
        let _ = model.noteListRendered() // swiftlint:disable:this redundant_discardable_let
        let searching = !model.trimmedQuery.isEmpty
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
                    .accessibilityIdentifier(section.identifier)
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
            PalGlassContainer(spacing: 8) {
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

    private func macRow(_ entry: ConnectListEntry) -> some View {
        let opens = entry.app.opensDetails
        let wholeRow = opens && entry.row.state.showsOpenMark
        return ConnectMacRow(
            title: entry.row.name, subtitle: entry.row.summary, problem: entry.row.hasProblem, identifier: "connectApp-\(entry.app.id)",
            open: opens ? { model.openDetails(entry.app) } : nil, opensWholeRow: wholeRow,
            icon: { ConnectorLogoTile(app: entry.app) },
            trailing: {
                if wholeRow {
                    ConnectOpenMark(state: entry.row.state)
                } else {
                    ConnectCapsule(state: entry.row.state, identifier: "connectApp-\(entry.app.id)-action") {
                        model.performRowAction(entry.app, state: entry.row.state)
                    }
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
                    .glassButtonStyle()
                    .accessibilityIdentifier("\(identifier)-action")
            case .openSettings:
                Button(localized) { model.devices.openSettings(for: id) }
                    .glassButtonStyle()
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
    var open: (() -> Void)?
    var opensWholeRow = false
    private let icon: Icon
    private let trailing: Trailing

    init(
        title: String, subtitle: String, problem: Bool, identifier: String, open: (() -> Void)? = nil, opensWholeRow: Bool = false,
        @ViewBuilder icon: () -> Icon, @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.problem = problem
        self.identifier = identifier
        self.open = open
        self.opensWholeRow = opensWholeRow
        self.icon = icon()
        self.trailing = trailing()
    }

    private var leading: some View {
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
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            if let open {
                if opensWholeRow {
                    Button(action: open) {
                        HStack(spacing: 12) {
                            leading
                            trailing
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("\(identifier)-open")
                } else {
                    Button(action: open) { leading.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("\(identifier)-open")
                    trailing
                }
            } else {
                leading
                trailing
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}
#endif
