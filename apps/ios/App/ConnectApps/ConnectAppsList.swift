import PalBotProfile
import PalConnect
import PalDesign
import PalDevice
import PalDiagnostics
import PalProtocol
import SwiftUI

struct ConnectAppsSearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .submitLabel(.search)
            #endif
            .accessibilityLabel(Text("Search apps and skills"))
            .accessibilityIdentifier("connectAppsSearch")
            .padding(.horizontal, PalMetrics.screenMargin)
            .padding(.bottom, PalMetrics.captionToCardGap)
    }
}

struct ConnectAppsList: View {
    @Bindable var model: ConnectAppsModel

    var body: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    private var iosBody: some View {
        let _ = PalPerf.event("connect.body.main") // swiftlint:disable:this redundant_discardable_let
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                resumeBanner
                ConnectAppsSearchField(text: $model.query, prompt: String(localized: "Search \(model.catalog.apps.count) apps"))
                content
                SetupButton(
                    title: String(localized: "Add a custom connector"), fillsWidth: true, identifier: "addCustomConnectorButton"
                ) { model.addCustomConnector() }
                    .padding(.top, PalMetrics.cardGap)
                    .padding(.horizontal, PalMetrics.screenMargin)
            }
            .padding(.bottom, PalMetrics.cardGap)
        }
        .scrollIndicators(.automatic)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    var resumeBanner: some View {
        if model.trimmedQuery.isEmpty, let offer = model.resumeOffer {
            SetupResumeBanner(offer: offer) { model.continueSetup(offer) }
                .padding(.horizontal, PalMetrics.screenMargin)
                .padding(.bottom, PalMetrics.captionToCardGap)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading where model.catalog.apps.isEmpty:
            DelayedProgressView().frame(maxWidth: .infinity).padding(.top, PalMetrics.cardGap).accessibilityIdentifier("connectAppsLoading")
        case .unavailable:
            StatusBlock(status: SetupStatus(code: "offline"), identifierPrefix: "connectAppsUnavailable") { Task { await model.reload() } }
                .padding(.top, PalMetrics.cardGap)
        default:
            loaded
        }
    }

    @ViewBuilder
    private var loaded: some View {
        let _ = model.noteListRendered() // swiftlint:disable:this redundant_discardable_let
        let searching = !model.trimmedQuery.isEmpty
        let sections = model.listSections
        let skills = model.searchedSkills
        if searching, sections.isEmpty, skills.isEmpty {
            Text("No matches")
                .foregroundStyle(PalTokens.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, PalMetrics.cardGap)
                .accessibilityIdentifier("connectAppsNoMatches")
        }
        if !searching { legacySection }
        ForEach(sections) { group in
            ConnectSectionHeader(group.section.title, accessibilityIdentifier: group.identifier)
            card {
                ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                    ConnectAppRowView(app: entry.app, row: entry.row, showsDivider: index > 0) {
                        model.performRowAction(entry.app, state: entry.row.state)
                    }
                }
            }
        }
        if searching {
            if !skills.isEmpty { skillResults(skills) }
        } else {
            deviceSection(model.devices.thisDevice)
            SkillsCatalogEntry { model.showsSkills = true }
            capabilitiesSection
        }
    }

    func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(PalTokens.elevated, in: RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous).strokeBorder(PalTokens.panelBorder, lineWidth: 1))
            .padding(.horizontal, PalMetrics.screenMargin)
    }

    func skillResults(_ skills: [InstalledSkill]) -> some View {
        Group {
            ConnectSectionHeader(String(localized: "Skills"), accessibilityIdentifier: "connectAppsSection-skills")
            card {
                ForEach(skills) { skill in
                    ConnectAppRow(
                        title: skill.name, summary: skill.category, accessibilityIdentifier: "skill-\(skill.id)",
                        inset: PalMetrics.screenMargin, trailing: nil
                    ) { PluginGlyphTile() }
                }
            }
        }
    }

    @ViewBuilder
    var legacySection: some View {
        switch model.legacy.display(in: model.catalog) {
        case .hidden:
            EmptyView()
        case .unreadable(let code):
            LegacyReadFailure(code: code, isBusy: model.legacy.isLoading) { Task { await model.retryLegacy() } }
        case .rows(let rows):
            ConnectSectionHeader(String(localized: "Reconnect your earlier apps"), accessibilityIdentifier: "legacyReconnectTitle")
            card {
                ForEach(rows) { row in
                    LegacyReconnectRowView(
                        row: row, isBusy: row.route.appID.map(model.busy.contains) ?? false,
                        reconnect: { Task { await model.reconnect(row) } }, dismiss: { model.legacy.dismiss(row) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func deviceSection(_ section: DeviceSection) -> some View {
        ConnectSectionHeader(section.title, accessibilityIdentifier: "connectAppsSection-device-\(section.id)")
        if !section.rows.isEmpty {
            card { ForEach(section.rows) { deviceRow($0) } }
        }
    }

    private func deviceRow(_ row: DeviceConnectorRow) -> some View {
        let look = DeviceRowPresentation(row: row)
        let identifier = "deviceConnector-\(row.id.rawValue)"
        return HStack(spacing: ConnectRowMetrics.tileToTextGap) {
            DeviceTile(connector: row.id)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.entry.title)
                    .font(.system(size: ConnectRowMetrics.titleSize))
                    .foregroundStyle(PalTokens.textPrimary)
                    .lineLimit(1)
                Text(look.summary)
                    .font(.system(size: ConnectRowMetrics.subtitleSize))
                    .foregroundStyle(PalTokens.textSecondary)
                    .lineLimit(ConnectRowMetrics.summaryLineLimit)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            deviceTrailing(look, id: row.id, identifier: identifier)
        }
        .padding(.horizontal, PalMetrics.screenMargin)
        .padding(.vertical, ConnectRowMetrics.verticalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private func deviceTrailing(_ look: DeviceRowPresentation, id: DeviceConnectorID, identifier: String) -> some View {
        if model.devices.busy.contains(id) {
            ProgressView().controlSize(.small)
        } else if let title = look.buttonTitle {
            let localized = String(localized: String.LocalizationValue(title))
            switch look.action {
            case .allow:
                SetupButton(title: localized, kind: .primary, identifier: "\(identifier)-action") { Task { await model.devices.allow(id) } }
                    .controlSize(.small)
            case .openSettings:
                SetupButton(title: localized, kind: .primary, identifier: "\(identifier)-action") { model.devices.openSettings(for: id) }
                    .controlSize(.small)
            case nil:
                Label(localized, palIcon: "checkmark", ink: .tertiary)
                    .font(.system(size: ConnectRowMetrics.subtitleSize))
                    .foregroundStyle(PalTokens.textTertiary)
                    .accessibilityIdentifier("\(identifier)-action")
            }
        }
    }

    @ViewBuilder
    var capabilitiesSection: some View {
        switch model.capabilitiesPhase {
        case .hidden:
            EmptyView()
        case .loading:
            ConnectSectionHeader(String(localized: "Capabilities"), accessibilityIdentifier: "capabilitiesTitle")
            DelayedProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, PalMetrics.screenMargin)
                .accessibilityIdentifier("capabilitiesLoading")
        case .failed:
            ConnectSectionHeader(String(localized: "Capabilities"), accessibilityIdentifier: "capabilitiesTitle")
            Text("Couldn't load capabilities")
                .font(.system(size: ConnectRowMetrics.captionSize))
                .foregroundStyle(PalTokens.textSecondary)
                .padding(.horizontal, PalMetrics.screenMargin)
                .accessibilityIdentifier("capabilitiesError")
        case .ready(let rows):
            if !rows.isEmpty {
                ConnectSectionHeader(String(localized: "Capabilities"), accessibilityIdentifier: "capabilitiesTitle")
                card {
                    ForEach(rows) { row in
                        CapabilityListRow(row: row, onSetKey: model.canSetKeys ? { model.beginKeyEntry(row, keyName: $0) } : nil)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("capabilitiesList")
            }
        }
    }
}

struct ConnectAppRowView: View {
    let app: ConnectApp
    let row: ConnectListRow
    var showsDivider = false
    let perform: () -> Void

    var body: some View {
        HStack(spacing: ConnectRowMetrics.tileToTextGap) {
            ConnectorLogoTile(app: app)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.system(size: ConnectRowMetrics.titleSize))
                    .foregroundStyle(PalTokens.textPrimary)
                    .lineLimit(1)
                Text(row.summary)
                    .font(.system(size: ConnectRowMetrics.subtitleSize))
                    .foregroundStyle(row.hasProblem ? Color.red : PalTokens.textSecondary)
                    .lineLimit(ConnectRowMetrics.summaryLineLimit)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            trailing
        }
        .padding(.horizontal, PalMetrics.screenMargin)
        .padding(.vertical, ConnectRowMetrics.verticalPadding)
        .overlay(alignment: .top) { if showsDivider { PalHairline() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectApp-\(app.id)")
    }

    @ViewBuilder
    private var trailing: some View {
        let identifier = "connectApp-\(app.id)-action"
        let title = row.state.actionTitle ?? ""
        switch row.state {
        case .connect, .setUp:
            SetupButton(title: title, identifier: identifier, action: perform).controlSize(.small)
        case .needsAttention:
            SetupButton(title: title, kind: .primary, identifier: identifier, action: perform).controlSize(.small)
        case .connected:
            SetupButton(title: title, symbol: "checkmark", identifier: identifier, action: perform).controlSize(.small)
        case .waiting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting")
                    .font(.system(size: ConnectRowMetrics.subtitleSize))
                    .foregroundStyle(PalTokens.textTertiary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier)
        case .unavailable:
            EmptyView()
        }
    }
}
