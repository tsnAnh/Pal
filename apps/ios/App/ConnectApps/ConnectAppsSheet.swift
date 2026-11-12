import PalBotProfile
import PalConnect
import PalDesign
import PalProtocol
import SwiftUI

struct ConnectAppsSheet: View {
    @State private var model: ConnectAppsModel
    let close: () -> Void

    @Environment(\.hermesTheme) private var theme

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
        default: id
        }
    }

    @ViewBuilder
    private var selectedSection: some View {
        switch model.selection {
        case ConnectChip.all: allSections
        case let category:
            ConnectSectionHeader(category, accessibilityIdentifier: "connectAppsSectionTitle")
            ForEach(model.catalog.apps(in: category)) { appRow($0) }
        }
    }

    @ViewBuilder
    private var allSections: some View {
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
    private var searchResults: some View {
        let apps = model.searchedApps
        let skills = model.searchedSkills
        if apps.isEmpty, skills.isEmpty {
            Text("No matches")
                .foregroundStyle(Color(theme.palette.textSecondary))
                .padding(.top, 60)
                .accessibilityIdentifier("connectAppsNoMatches")
        }
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
        if apps.isEmpty {
            Text("Nothing connected yet")
                .foregroundStyle(Color(theme.palette.textSecondary))
                .padding(.top, 60)
                .accessibilityIdentifier("yourPluginsEmpty")
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
