import PalBotProfile
import PalConnect
import PalDesign
import PalProtocol
import SwiftUI

struct ConnectAppsSheet: View {
    @State private var model: ConnectAppsModel
    let close: () -> Void

    @Environment(\.hermesTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase

    private static let rowsPerSectionInAll = 4

    init(model: ConnectAppsModel, close: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.close = close
    }

    private var onCatalog: Bool { model.page == .catalog }

    var body: some View {
        Group {
            if let connector = model.customConnector {
                customConnectorChrome(connector)
            } else {
                listChrome
            }
        }
        .task { await model.start() }
        .onDisappear { Task { await model.stop() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refreshPermissions() } }
        }
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
        .alert(
            model.disconnectTarget.map { "\(disconnectVerb($0)) \($0.name)?" } ?? "",
            isPresented: Binding(get: { model.disconnectTarget != nil }, set: { if !$0 { model.disconnectTarget = nil } }),
            presenting: model.disconnectTarget
        ) { target in
            Button(disconnectVerb(target), role: .destructive) { Task { await model.disconnect(target) } }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text(disconnectMessage(target))
        }
        .sheet(isPresented: $model.showsSkills) {
            SkillsCatalogSheet(model: model.makeSkillsModel(), botName: model.botName) { model.showsSkills = false }
                .macSheetFrame()
        }
        .sheet(item: $model.accountsModel) { accounts in
            ConnectorAccountsView(model: accounts)
                .macSheetFrame()
        }
        .sheet(item: $model.keyRequest) { request in
            CapabilityKeyEntrySheet(model: model, request: request)
                .presentationDetents([.medium])
                .macSheetFrame()
        }
        .sheet(item: $model.credentialPrompt) { prompt in
            CredentialSheet(prompt: prompt) { values in
                Task { await model.connect(prompt.app, credentials: values) }
            }
            .macSheetFrame()
        }
    }

    private func customConnectorChrome(_ connector: CustomConnectorModel) -> some View {
        SheetChrome(
            leading: .back,
            accessibilityIdentifier: "connectApps",
            leadingAccessibilityIdentifier: "customConnectorBackButton",
            onLeading: { Task { await model.leaveCustomConnector() } },
            trailing: {
                Button(role: .close) { close() }
                    .tint(.primary)
                    .accessibilityIdentifier("customConnectorCloseButton")
            },
            content: {
                CustomConnectorForm(model: connector, style: .phone(theme)) { Task { await model.leaveCustomConnector() } }
            }
        )
    }

    private var listChrome: some View {
        SheetChrome(
            title: onCatalog ? "Connect apps" : "Your plugins",
            leading: onCatalog ? .close : .back,
            titleAlignment: .afterLeadingButton,
            accessibilityIdentifier: "connectApps",
            onLeading: { if onCatalog { close() } else { model.page = .catalog } },
            trailing: {
                if onCatalog {
                    ConnectedCountButton("\(model.connectedCount) connected", accessibilityIdentifier: "connectedCountButton") {
                        model.page = .yourPlugins
                    }
                }
            },
            content: {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if onCatalog { catalogContent } else { yourPluginsContent }
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.automatic)
                .scrollDismissesKeyboard(.interactively)
                .safeAreaBar(edge: .bottom) {
                    VStack(spacing: 10) {
                        if onCatalog {
                            FloatingSearchBar(
                                text: $model.query,
                                prompt: "Search across apps and skills",
                                accessibilityLabel: "Search across apps and skills",
                                accessibilityIdentifier: "connectAppsSearch"
                            )
                        }
                        PillButton("Add a custom connector", size: .large, accessibilityIdentifier: "addCustomConnectorButton") {
                            model.addCustomConnector()
                        }
                    }
                }
            }
        )
    }

    private func disconnectVerb(_ target: ConnectDisconnectTarget) -> String {
        if case .device = target { "Turn off" } else { "Disconnect" }
    }

    private func disconnectMessage(_ target: ConnectDisconnectTarget) -> String {
        switch target {
        case .device: "\(model.botName) won't be able to use it until you turn it back on."
        case .app: "\(model.botName) loses access to this app until you connect it again."
        }
    }

    @ViewBuilder
    private var catalogContent: some View {
        if model.trimmedQuery.isEmpty {
            FilterChipBar(
                items: model.chips.map { FilterChipItem(id: $0, title: chipTitle($0)) },
                selection: $model.selection,
                accessibilityIdentifier: "connectAppsChips"
            )
        }
        switch model.phase {
        case .loading where model.catalog.apps.isEmpty:
            ProgressView().padding(.top, 60).accessibilityIdentifier("connectAppsLoading")
        case .unavailable:
            unavailable
        default:
            if !model.trimmedQuery.isEmpty { searchResults } else { selectedSection }
        }
    }

    private func chipTitle(_ id: String) -> String {
        switch id {
        case ConnectChip.all: "All"
        case ConnectChip.iphone: "iPhone"
        default: id
        }
    }

    @ViewBuilder
    private var selectedSection: some View {
        switch model.selection {
        case ConnectChip.all: allSections
        case ConnectChip.iphone: iphoneSection(showsCaption: true)
        case let category:
            ConnectSectionHeader(category, accessibilityIdentifier: "connectAppsSectionTitle")
            ForEach(model.catalog.apps(in: category)) { appRow($0) }
        }
    }

    @ViewBuilder
    private var allSections: some View {
        GitHubAccountSection(model: model.github)
        ConnectSectionHeader("This iPhone", accessibilityIdentifier: "connectAppsSection-iphone") { model.selection = ConnectChip.iphone }
        ForEach(model.deviceRows, id: \.renderID) { deviceRow($0) }
        ForEach(model.catalog.categories, id: \.self) { category in
            ConnectSectionHeader(category, accessibilityIdentifier: "connectAppsSection-\(category)") { model.selection = category }
            ForEach(model.catalog.apps(in: category).prefix(Self.rowsPerSectionInAll)) { appRow($0) }
        }
        SkillsCatalogEntry { model.showsSkills = true }
        capabilitiesSection
    }

    @ViewBuilder
    private var capabilitiesSection: some View {
        switch model.capabilitiesPhase {
        case .hidden:
            EmptyView()
        case .loading:
            ConnectSectionHeader("Capabilities", accessibilityIdentifier: "capabilitiesTitle")
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12).accessibilityIdentifier("capabilitiesLoading")
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
                VStack(spacing: 0) {
                    ForEach(rows) { row in CapabilityListRow(row: row, onSetKey: model.canSetKeys ? { model.beginKeyEntry(row, keyName: $0) } : nil) }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("capabilitiesList")
            }
        }
    }

    @ViewBuilder
    private func iphoneSection(showsCaption: Bool) -> some View {
        ConnectSectionHeader("This iPhone", accessibilityIdentifier: "connectAppsSectionTitle")
        if showsCaption {
            Text("Turn iPhone connectors on here, or \(model.botName) will ask the first time it needs one.")
                .font(.system(size: ConnectRowMetrics.captionSize))
                .foregroundStyle(Color(theme.palette.textSecondary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ConnectRowMetrics.horizontalMargin)
                .padding(.bottom, 10)
                .accessibilityIdentifier("connectAppsIphoneCaption")
        }
        ForEach(model.deviceRows, id: \.renderID) { deviceRow($0) }
    }

    @ViewBuilder
    private var searchResults: some View {
        let devices = model.searchedDevices
        let apps = model.searchedApps
        let skills = model.searchedSkills
        if devices.isEmpty, apps.isEmpty, skills.isEmpty {
            Text("No matches")
                .foregroundStyle(Color(theme.palette.textSecondary))
                .padding(.top, 60)
                .accessibilityIdentifier("connectAppsNoMatches")
        }
        ForEach(devices, id: \.renderID) { deviceRow($0) }
        ForEach(apps) { appRow($0) }
        if !skills.isEmpty {
            ConnectSectionHeader("Skills", accessibilityIdentifier: "connectAppsSection-skills")
            ForEach(skills) { skill in
                ConnectAppRow(title: skill.name, summary: skill.category, accessibilityIdentifier: "skill-\(skill.id)", trailing: nil) { PluginGlyphTile() }
            }
        }
    }

    private var unavailable: some View {
        VStack(spacing: 14) {
            Text("Couldn't load apps")
                .foregroundStyle(Color(theme.palette.textSecondary))
            PillButton("Try again", accessibilityIdentifier: "connectAppsRetry") { Task { await model.reload() } }
        }
        .padding(.top, 60)
        .accessibilityIdentifier("connectAppsUnavailable")
    }

    @ViewBuilder
    private var yourPluginsContent: some View {
        let apps = model.connectedApps
        let devices = model.connectedDeviceRows
        if apps.isEmpty, devices.isEmpty {
            Text("Nothing connected yet")
                .foregroundStyle(Color(theme.palette.textSecondary))
                .padding(.top, 60)
                .accessibilityIdentifier("yourPluginsEmpty")
        }
        if !devices.isEmpty {
            ConnectSectionHeader("This iPhone", accessibilityIdentifier: "yourPluginsSection-iphone")
            ForEach(devices) { row in
                ConnectAppRow(
                    title: row.title, summary: row.subtitle, accessibilityIdentifier: "yourPlugin-device-\(row.id.rawValue)",
                    isBusy: model.busy.contains("device:\(row.id.rawValue)"),
                    trailing: ConnectRowAction("Turn off") { model.disconnectTarget = .device(row) }
                ) { DeviceTile(connector: row.id) }
            }
        }
        if !apps.isEmpty {
            ConnectSectionHeader("Apps", accessibilityIdentifier: "yourPluginsSection-apps")
            ForEach(apps) { app in
                ConnectAppRow(
                    title: app.name, summary: app.summary, accessibilityIdentifier: "yourPlugin-\(app.id)",
                    isBusy: model.busy.contains(app.id),
                    trailing: ConnectRowAction("Disconnect") { model.disconnectTarget = .app(app) }
                ) { icon(for: app) }
                .contextMenu {
                    if case .hosted = app.source { Button("Accounts") { model.manageAccounts(app) } }
                }
            }
        }
    }

    private func appRow(_ app: ConnectApp) -> some View {
        let action: ConnectRowAction = if case .custom = app.source {
            ConnectRowAction("Manage") { model.manage(app) }
        } else {
            switch app.state {
        case .disconnected: ConnectRowAction("Connect") { Task { await model.connect(app) } }
        case .needsAuthorization: ConnectRowAction("Authorize", kind: .accent) { Task { await model.connect(app) } }
        case .connected: ConnectRowAction("Manage") { model.manageAccounts(app) }
            }
        }
        return ConnectAppRow(
            title: app.name, summary: app.summary, accessibilityIdentifier: "connectApp-\(app.id)",
            isBusy: model.busy.contains(app.id), trailing: action
        ) { icon(for: app) }
    }

    @ViewBuilder
    private func icon(for app: ConnectApp) -> some View {
        switch app.source {
        case .hosted: RemoteLogoTile(url: app.iconURL)
        case .mcp, .custom: PluginGlyphTile()
        }
    }

    private func deviceRow(_ row: DeviceRow) -> some View {
        let action: ConnectRowAction = switch row.action {
        case .allow: ConnectRowAction("Allow", kind: .accent) { Task { await model.allow(row) } }
        case .allowInSettings: ConnectRowAction("Allow in Settings", kind: .accent) { model.openSettings(for: row) }
        case .connected: ConnectRowAction("Connected", kind: .dimmed) { model.disconnectTarget = .device(row) }
        }
        return ConnectAppRow(
            title: row.title, summary: row.subtitle, accessibilityIdentifier: "deviceConnector-\(row.id.rawValue)",
            isBusy: model.busy.contains("device:\(row.id.rawValue)"), trailing: action
        ) { DeviceTile(connector: row.id) }
    }
}

struct DeviceTile: View {
    let connector: DeviceConnectorID

    var body: some View {
        AppTile(style: .filled(color)) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var symbol: String {
        switch connector {
        case .calendar: "calendar"
        case .home: "house.fill"
        case .reminders: "checklist"
        case .contacts: "person.crop.circle.fill"
        case .location: "location.fill"
        case .alarms: "alarm.fill"
        case .shell, .files: "desktopcomputer"
        case .input: "cursorarrow.click.2"
        case .screen: "display"
        case .notifications: "bell.fill"
        case .apps: "macwindow"
        case .clipboard: "doc.on.clipboard.fill"
        }
    }

    private var color: RGB {
        switch connector {
        case .calendar: RGB(hex: 0xe5493a)
        case .home: RGB(hex: 0xf58903)
        case .reminders: RGB(hex: 0x2d7cf6)
        case .contacts: RGB(hex: 0x8e8e93)
        case .location: RGB(hex: 0x1c65cb)
        case .alarms: RGB(hex: 0x2c2c2e)
        case .shell, .files: RGB(hex: 0x3a3a3c)
        case .input: RGB(hex: 0x6e4ccf)
        case .screen: RGB(hex: 0x6e4bd8)
        case .notifications: RGB(hex: 0xe5493a)
        case .apps: RGB(hex: 0x5e5ce6)
        case .clipboard: RGB(hex: 0x8e6bd8)
        }
    }
}

struct CredentialSheet: View {
    let prompt: CredentialPrompt
    let submit: ([String: String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.hermesTheme) private var theme
    @State private var values: [String: String] = [:]

    private var complete: Bool { prompt.keys.allSatisfy { values[$0]?.isEmpty == false } }

    var body: some View {
        SheetChrome(
            title: "Connect \(prompt.app.name)",
            accessibilityIdentifier: "connectCredentials",
            onLeading: { dismiss() },
            content: {
                VStack(spacing: 16) {
                    ForEach(prompt.keys, id: \.self) { key in
                        SecureField(key, text: Binding(get: { values[key] ?? "" }, set: { values[key] = $0 }))
                            .textContentType(.password)
                            .neverAutocapitalized()
                            .autocorrectionDisabled()
                            .padding(.horizontal, 16)
                            .frame(height: 48)
                            .background(Color(theme.palette.groupedCard), in: RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
                            .accessibilityIdentifier("connectCredential-\(key)")
                    }
                    PillButton("Connect", kind: complete ? .accent : .dimmed, size: .large, accessibilityIdentifier: "connectCredentialsSubmit") {
                        submit(values)
                        dismiss()
                    }
                }
                .padding(.horizontal, PalMetrics.screenMargin)
            }
        )
        .presentationDetents([.medium])
    }
}

private struct CapabilityListRow: View {
    let row: CapabilityRow
    let onSetKey: ((String) -> Void)?

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: ConnectRowMetrics.tileToTextGap) {
            Image(systemName: row.indicator.symbolName)
                .font(.system(size: 20))
                .foregroundStyle(indicatorColor)
                .frame(width: ConnectRowMetrics.tileSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(row.label)
                        .font(.system(size: ConnectRowMetrics.titleSize))
                        .foregroundStyle(Color(theme.palette.textPrimary))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(row.stateWord)
                        .font(.system(size: ConnectRowMetrics.subtitleSize))
                        .foregroundStyle(Color(theme.palette.textSecondary))
                }
                if let reason = row.reason {
                    Text(reason)
                        .font(.system(size: ConnectRowMetrics.subtitleSize))
                        .foregroundStyle(Color(theme.palette.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let key = row.shownKeyName {
                    Text(key)
                        .font(.system(size: ConnectRowMetrics.subtitleSize, design: .monospaced))
                        .foregroundStyle(Color(theme.palette.chipText))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(theme.palette.chipFill), in: Capsule())
                        .padding(.top, 2)
                }
                if let onSetKey {
                    CapabilitySetKeyButton(row: row, onSelect: onSetKey)
                        .font(.system(size: ConnectRowMetrics.subtitleSize, weight: .semibold))
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, ConnectRowMetrics.horizontalMargin)
        .padding(.vertical, ConnectRowMetrics.verticalPadding)
        .accessibilityElement(children: onSetKey == nil ? .combine : .contain)
        .accessibilityLabel(Text(row.accessibilitySummary))
        .accessibilityIdentifier(row.accessibilityIdentifier)
    }

    private var indicatorColor: Color {
        switch row.indicator {
        case .on: Color(theme.palette.toggleOnTrack)
        case .limited: Color(theme.palette.accentBlue)
        case .off, .unavailable: Color(theme.palette.textTertiary)
        }
    }
}
