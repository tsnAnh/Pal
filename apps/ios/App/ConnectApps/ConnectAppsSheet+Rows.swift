import PalBotProfile
import PalConnect
import PalDesign
import PalDevice
import PalProtocol
import SwiftUI

extension ConnectAppsSheet {
    @ViewBuilder
    var catalogContent: some View {
        if model.trimmedQuery.isEmpty {
            FilterChipBar(
                items: model.chips.map { FilterChipItem(id: $0, title: chipTitle($0)) },
                selection: $model.selection,
                accessibilityIdentifier: "connectAppsChips"
            )
        }
        switch model.phase {
        case .loading where model.catalog.apps.isEmpty:
            DelayedProgressView().padding(.top, 60).accessibilityIdentifier("connectAppsLoading")
        case .unavailable:
            unavailable
        default:
            if !model.trimmedQuery.isEmpty { searchResults } else { selectedSection }
        }
    }

    func chipTitle(_ id: String) -> String {
        switch id {
        case ConnectChip.all: "All"
        default: id
        }
    }

    @ViewBuilder
    var selectedSection: some View {
        switch model.selection {
        case ConnectChip.all: allSections
        case let category:
            ConnectSectionHeader(category, accessibilityIdentifier: "connectAppsSectionTitle")
            card { ForEach(model.catalog.apps(in: category)) { appRow($0) } }
        }
    }

    @ViewBuilder
    var allSections: some View {
        legacySection
        deviceSection(model.devices.thisDevice)
        ForEach(model.catalog.categories, id: \.self) { category in
            ConnectSectionHeader(category, accessibilityIdentifier: "connectAppsSection-\(category)") { model.selection = category }
            card { ForEach(model.catalog.apps(in: category).prefix(Self.rowsPerSectionInAll)) { appRow($0) } }
        }
        SkillsCatalogEntry { model.showsSkills = true }
        capabilitiesSection
    }

    @ViewBuilder
    func deviceSection(_ section: DeviceSection) -> some View {
        ConnectSectionHeader(section.title, accessibilityIdentifier: "connectAppsSection-device-\(section.id)")
        if !section.rows.isEmpty { card { ForEach(section.rows) { deviceRow($0) } } }
    }

    func deviceRow(_ row: DeviceConnectorRow) -> some View {
        let look = DeviceRowPresentation(row: row)
        return ConnectAppRow(
            title: row.entry.title, summary: look.summary, accessibilityIdentifier: "deviceConnector-\(row.id.rawValue)",
            isBusy: model.devices.busy.contains(row.id), inset: Self.cardInset, trailing: deviceAction(look, row.id)
        ) { DeviceTile(connector: row.id) }
    }

    func deviceAction(_ look: DeviceRowPresentation, _ id: DeviceConnectorID) -> ConnectRowAction? {
        guard let title = look.buttonTitle else { return nil }
        switch look.action {
        case .allow: return ConnectRowAction(title, kind: .accent) { Task { await model.devices.allow(id) } }
        case .openSettings: return ConnectRowAction(title, kind: .accent) { model.devices.openSettings(for: id) }
        case nil: return ConnectRowAction(title, kind: .dimmed) {}
        }
    }

    @ViewBuilder
    var capabilitiesSection: some View {
        switch model.capabilitiesPhase {
        case .hidden:
            EmptyView()
        case .loading:
            ConnectSectionHeader("Capabilities", accessibilityIdentifier: "capabilitiesTitle")
            DelayedProgressView().frame(maxWidth: .infinity).padding(.vertical, 12).accessibilityIdentifier("capabilitiesLoading")
        case .failed:
            ConnectSectionHeader("Capabilities", accessibilityIdentifier: "capabilitiesTitle")
            Text("Couldn't load capabilities")
                .font(.system(size: ConnectRowMetrics.captionSize))
                .foregroundStyle(Color(theme.palette.textSecondary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ConnectRowMetrics.horizontalMargin)
                .padding(.vertical, 8)
                .accessibilityIdentifier("capabilitiesError")
        case .ready(let rows):
            if !rows.isEmpty {
                ConnectSectionHeader("Capabilities", accessibilityIdentifier: "capabilitiesTitle")
                card {
                    ForEach(rows) { row in CapabilityListRow(row: row, onSetKey: model.canSetKeys ? { model.beginKeyEntry(row, keyName: $0) } : nil) }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("capabilitiesList")
            }
        }
    }

    @ViewBuilder
    var searchResults: some View {
        let apps = model.searchedApps
        let skills = model.searchedSkills
        if apps.isEmpty, skills.isEmpty {
            Text("No matches")
                .foregroundStyle(Color(theme.palette.textSecondary))
                .padding(.top, 60)
                .accessibilityIdentifier("connectAppsNoMatches")
        }
        if !apps.isEmpty {
            card { ForEach(apps) { appRow($0) } }
                .padding(.top, 12)
        }
        if !skills.isEmpty {
            ConnectSectionHeader("Skills", accessibilityIdentifier: "connectAppsSection-skills")
            card {
                ForEach(skills) { skill in
                    ConnectAppRow(
                        title: skill.name, summary: skill.category, accessibilityIdentifier: "skill-\(skill.id)",
                        inset: Self.cardInset, trailing: nil
                    ) { PluginGlyphTile() }
                }
            }
        }
    }

    var unavailable: some View {
        VStack(spacing: 14) {
            Text("Couldn't load apps")
                .foregroundStyle(Color(theme.palette.textSecondary))
            PillButton("Try again", accessibilityIdentifier: "connectAppsRetry") { Task { await model.reload() } }
        }
        .padding(.top, 60)
        .accessibilityIdentifier("connectAppsUnavailable")
    }

    @ViewBuilder
    var yourPluginsContent: some View {
        let apps = model.connectedApps
        if apps.isEmpty {
            Text("Nothing connected yet")
                .foregroundStyle(Color(theme.palette.textSecondary))
                .padding(.top, 60)
                .accessibilityIdentifier("yourPluginsEmpty")
        }
        if !apps.isEmpty {
            ConnectSectionHeader("Apps", accessibilityIdentifier: "yourPluginsSection-apps")
            card {
                ForEach(apps) { app in
                    ConnectAppRow(
                        title: app.name, summary: app.summary, accessibilityIdentifier: "yourPlugin-\(app.id)",
                        isBusy: model.busy.contains(app.id), status: ConnectAppStatus(app.state).row, inset: Self.cardInset,
                        trailing: ConnectRowAction("Disconnect") { model.disconnectTarget = .app(app) }
                    ) { icon(for: app) }
                }
            }
        }
    }

    func upworkRow(_ app: ConnectApp) -> some View {
        let state = model.cardState(app)
        return ConnectAppRow(
            title: app.name, summary: UpworkCardText.summary(state, fallback: app.summary), accessibilityIdentifier: "connectApp-\(app.id)",
            isBusy: state == .connecting, status: ConnectAppStatus(app.state).row, inset: Self.cardInset,
            trailing: ConnectRowAction(UpworkCardText.actionTitle(state), kind: state.isReconnect ? .accent : .neutral) { model.upworkApp = app }
        ) { icon(for: app) }
    }

    @ViewBuilder
    func appRow(_ app: ConnectApp) -> some View {
        if app.requiresAppSignIn {
            upworkRow(app)
        } else {
            plainRow(app)
        }
    }

    func plainRow(_ app: ConnectApp) -> some View {
        let action: ConnectRowAction? = if case .custom = app.source {
            ConnectRowAction("Manage") { model.manage(app) }
        } else if app.isBotApp {
            ConnectRowAction(model.slackActionTitle, kind: model.slack.installedCount > 0 ? .neutral : .accent) { model.showsSlackPicker = true }
        } else if app.oauthClientEntry != nil {
            ConnectRowAction(OAuthClientCardText.actionTitle(app.state), kind: OAuthClientCardText.prominent(app.state) ? .accent : .neutral) {
                model.oauthClientAction(app)
            }
        } else {
            switch app.state {
            case .disconnected: ConnectRowAction(OtherConnectorCardText.connectTitle(model.cardState(app))) { Task { await model.connect(app) } }
            case .needsAuthorization: ConnectRowAction("Authorize", kind: .accent) { Task { await model.connect(app) } }
            case .needsSetup: nil
            case .connected:
                if app.requiresToken {
                    ConnectRowAction("Update token") { Task { await model.connect(app) } }
                } else {
                    ConnectRowAction("Manage") { model.manageAccounts(app) }
                }
            }
        }
        return ConnectAppRow(
            title: app.name, summary: OtherConnectorCardText.summary(model.cardState(app), fallback: app.summary),
            accessibilityIdentifier: "connectApp-\(app.id)",
            isBusy: model.busy.contains(app.id), status: app.isBotApp ? model.slackStatus : ConnectAppStatus(app.state).row,
            inset: Self.cardInset, trailing: action
        ) { icon(for: app) }
    }

    @ViewBuilder
    func icon(for app: ConnectApp) -> some View {
        switch app.source {
        case .catalog: ConnectorLogoTile(app: app)
        case .mcp, .custom, .googleWorkspace: PluginGlyphTile()
        }
    }
}
