import PalBotProfile
import PalConnect
import PalDesign
import PalDevice
import PalProtocol
import SwiftUI

struct ConnectAppsSheet: View {
    @State private var model: ConnectAppsModel
    let close: () -> Void

    @Environment(\.hermesTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase

    private static let rowsPerSectionInAll = 4
    private static let cardInset: CGFloat = 14

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
        .googleAuthTracking(model.google)
        .onDisappear { Task { await model.stop() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.devices.refresh() } }
        }
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
        .alert(
            model.disconnectTarget.map { "Disconnect \($0.name)?" } ?? "",
            isPresented: Binding(get: { model.disconnectTarget != nil }, set: { if !$0 { model.disconnectTarget = nil } }),
            presenting: model.disconnectTarget
        ) { target in
            Button("Disconnect", role: .destructive) { Task { await model.disconnect(target) } }
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
        .sheet(item: $model.upworkApp) { app in
            UpworkConnectionSheet(model: model, app: app)
                .macSheetFrame()
        }
        .sheet(item: $model.googleApp) { _ in
            GoogleWorkspaceSheet(model: model.google)
                .macSheetFrame()
        }
        .sheet(item: $model.pastingApp, onDismiss: { Task { await model.cancelPaste() } }) { app in
            OtherConnectorPasteSheet(model: model, app: app)
                .macSheetFrame()
        }
        .sheet(item: $model.keyRequest) { request in
            CapabilityKeyEntrySheet(model: model, request: request)
                .presentationDetents([.medium])
                .macSheetFrame()
        }
        .sheet(item: $model.credentialPrompt) { prompt in
            CredentialSheet(prompt: prompt, botName: model.botName) { values in
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
                        PillButton("Add a custom connector", size: .large, accessibilityIdentifier: "addCustomConnectorButton") {
                            model.addCustomConnector()
                        }
                        .padding(.top, 32)
                        .padding(.horizontal, PalMetrics.screenMargin)
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.automatic)
                .scrollDismissesKeyboard(.interactively)
                .safeAreaBar(edge: .bottom) {
                    if onCatalog {
                        FloatingSearchBar(
                            text: $model.query,
                            prompt: "Search across apps and skills",
                            accessibilityLabel: "Search across apps and skills",
                            accessibilityIdentifier: "connectAppsSearch"
                        )
                    }
                }
            }
        )
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.vertical, 2)
            .kanbanGlass(RoundedRectangle(cornerRadius: PalMetrics.tileRadius, style: .continuous))
            .padding(.horizontal, PalMetrics.screenMargin)
    }

    private func disconnectMessage(_ target: ConnectDisconnectTarget) -> String {
        "\(model.botName) loses access to this app until you connect it again."
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
            DelayedProgressView().padding(.top, 60).accessibilityIdentifier("connectAppsLoading")
        case .unavailable:
            unavailable
        default:
            if !model.trimmedQuery.isEmpty { searchResults } else { selectedSection }
        }
    }

    private func chipTitle(_ id: String) -> String {
        switch id {
        case ConnectChip.all: "All"
        default: id
        }
    }

    @ViewBuilder
    private var selectedSection: some View {
        switch model.selection {
        case ConnectChip.all: allSections
        case let category:
            ConnectSectionHeader(category, accessibilityIdentifier: "connectAppsSectionTitle")
            card { ForEach(model.catalog.apps(in: category)) { appRow($0) } }
        }
    }

    @ViewBuilder
    private var allSections: some View {
        deviceSection(model.devices.thisDevice)
        ForEach(model.catalog.categories, id: \.self) { category in
            ConnectSectionHeader(category, accessibilityIdentifier: "connectAppsSection-\(category)") { model.selection = category }
            card { ForEach(model.catalog.apps(in: category).prefix(Self.rowsPerSectionInAll)) { appRow($0) } }
        }
        SkillsCatalogEntry { model.showsSkills = true }
        capabilitiesSection
    }

    @ViewBuilder
    private func deviceSection(_ section: DeviceSection) -> some View {
        ConnectSectionHeader(section.title, accessibilityIdentifier: "connectAppsSection-device-\(section.id)")
        if !section.rows.isEmpty { card { ForEach(section.rows) { deviceRow($0) } } }
    }

    private func deviceRow(_ row: DeviceConnectorRow) -> some View {
        let look = DeviceRowPresentation(row: row)
        return ConnectAppRow(
            title: row.entry.title, summary: look.summary, accessibilityIdentifier: "deviceConnector-\(row.id.rawValue)",
            isBusy: model.devices.busy.contains(row.id), inset: Self.cardInset, trailing: deviceAction(look, row.id)
        ) { DeviceTile(connector: row.id) }
    }

    private func deviceAction(_ look: DeviceRowPresentation, _ id: DeviceConnectorID) -> ConnectRowAction? {
        guard let title = look.buttonTitle else { return nil }
        switch look.action {
        case .allow: return ConnectRowAction(title, kind: .accent) { Task { await model.devices.allow(id) } }
        case .openSettings: return ConnectRowAction(title, kind: .accent) { model.devices.openSettings(for: id) }
        case nil: return ConnectRowAction(title, kind: .dimmed) {}
        }
    }

    @ViewBuilder
    private var capabilitiesSection: some View {
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
    private var searchResults: some View {
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
                    ConnectAppRow(title: skill.name, summary: skill.category, accessibilityIdentifier: "skill-\(skill.id)", inset: Self.cardInset, trailing: nil) { PluginGlyphTile() }
                }
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
                    .contextMenu {
                        if case .hosted = app.source { Button("Accounts") { model.manageAccounts(app) } }
                    }
                }
            }
        }
    }

    private func upworkRow(_ app: ConnectApp) -> some View {
        let state = model.cardState(app)
        return ConnectAppRow(
            title: app.name, summary: UpworkCardText.summary(state, fallback: app.summary), accessibilityIdentifier: "connectApp-\(app.id)",
            isBusy: state == .connecting, status: ConnectAppStatus(app.state).row, inset: Self.cardInset,
            trailing: ConnectRowAction(UpworkCardText.actionTitle(state), kind: state.isReconnect ? .accent : .neutral) { model.upworkApp = app }
        ) { icon(for: app) }
    }

    private func googleRow(_ listed: ConnectApp) -> some View {
        let app = model.googleRow(listed)
        return ConnectAppRow(
            title: app.name, summary: GoogleWorkspaceText.summary(app), accessibilityIdentifier: "connectApp-\(app.id)",
            isBusy: model.google.isSigningIn, status: ConnectAppStatus(app.state).row, inset: Self.cardInset,
            trailing: ConnectRowAction(GoogleWorkspaceText.actionTitle(app.state), kind: app.state == .needsAuthorization ? .accent : .neutral) { model.googleApp = app }
        ) { icon(for: app) }
    }

    @ViewBuilder
    private func appRow(_ app: ConnectApp) -> some View {
        if app.requiresAppSignIn {
            upworkRow(app)
        } else if app.source == .googleWorkspace {
            googleRow(app)
        } else {
            plainRow(app)
        }
    }

    private func plainRow(_ app: ConnectApp) -> some View {
        let action: ConnectRowAction = if case .custom = app.source {
            ConnectRowAction("Manage") { model.manage(app) }
        } else {
            switch app.state {
        case .disconnected: ConnectRowAction(OtherConnectorCardText.connectTitle(model.cardState(app))) { Task { await model.connect(app) } }
        case .needsAuthorization: ConnectRowAction("Authorize", kind: .accent) { Task { await model.connect(app) } }
        case .connected:
            if case .mcp(_, let requires) = app.source, !requires.isEmpty {
                ConnectRowAction("Update token") { Task { await model.connect(app) } }
            } else {
                ConnectRowAction("Manage") { model.manageAccounts(app) }
            }
            }
        }
        return ConnectAppRow(
            title: app.name, summary: OtherConnectorCardText.summary(model.cardState(app), fallback: app.summary),
            accessibilityIdentifier: "connectApp-\(app.id)",
            isBusy: model.busy.contains(app.id), status: ConnectAppStatus(app.state).row, inset: Self.cardInset, trailing: action
        ) { icon(for: app) }
    }

    @ViewBuilder
    private func icon(for app: ConnectApp) -> some View {
        switch app.source {
        case .hosted: RemoteLogoTile(url: app.iconURL)
        case .mcp, .custom, .googleWorkspace: PluginGlyphTile()
        }
    }
}

extension ConnectAppStatus {
    var row: ConnectRowStatus {
        switch self {
        case .connected: ConnectRowStatus(title, tone: .positive)
        case .needsSignIn: ConnectRowStatus(title, tone: .attention)
        case .notConnected: ConnectRowStatus(title, tone: .neutral)
        }
    }
}

struct CredentialSheet: View {
    let prompt: CredentialPrompt
    let botName: String
    let submit: ([String: String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]

    private var pending: String? { prompt.keys.first { values[$0] == nil } }

    var body: some View {
        SheetChrome(
            title: "Connect \(prompt.app.name)",
            accessibilityIdentifier: "connectCredentials",
            onLeading: { dismiss() },
            content: {
                if let key = pending {
                    SecretEntryView(
                        connectorName: prompt.app.name,
                        accountLabel: botName,
                        purpose: prompt.app.setup.isEmpty ? String(localized: "Paste the key for \(key). It is saved for \(botName) only and can't be read back.") : prompt.app.setup,
                        fieldLabel: key,
                        submitTitle: String(localized: "Connect"),
                        state: .idle,
                        identifiers: SecretEntryIdentifiers(
                            field: "connectCredential-\(key)", submit: "connectCredentialsSubmit",
                            cancel: "connectCredentialsCancel", status: "connectCredentialsStatus"
                        ),
                        onSubmit: { value in
                            values[key] = value
                            if pending == nil {
                                submit(values)
                                dismiss()
                            }
                        },
                        onCancel: { dismiss() }
                    )
                    .id(key)
                    .padding(.horizontal, PalMetrics.screenMargin)
                }
            }
        )
        .presentationDetents([.medium, .large])
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
        .padding(.horizontal, 14)
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
