#if os(macOS)
import PalBotProfile
import PalConnect
import PalDesign
import PalDevice
import PalProtocol
import PalT3Code
import SwiftUI

struct MacConnectApps: View {
    @State var model: ConnectAppsModel

    @State var confirmsT3Disconnect = false
    @Environment(\.scenePhase) private var scenePhase

    static let rowsPerSectionInAll = 6
    let columns = [GridItem(.flexible(), spacing: 30), GridItem(.flexible(), spacing: 30)]

    init(model: ConnectAppsModel) {
        _model = State(initialValue: model)
    }

    var onCatalog: Bool { model.page == .catalog }

    var body: some View {
        Group {
            if let connector = model.customConnector {
                customConnectorPanel(connector)
            } else {
                listPanel
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectApps")
        .task { await model.start() }
        .googleAuthTracking(model.google)
        .onDisappear { Task { await model.stop() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.devices.refresh() } }
        }
        .alert(String(localized: "Disconnect T3 Code?"), isPresented: $confirmsT3Disconnect) {
            Button(String(localized: "Disconnect"), role: .destructive) { Task { await model.devices.t3.controller.disconnect() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(model.botName) can no longer send coding work to T3 Code on this Mac.")
        }
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
        .alert(
            model.disconnectTarget.map { String(localized: "Disconnect \($0.name)?") } ?? "",
            isPresented: Binding(get: { model.disconnectTarget != nil }, set: { if !$0 { model.disconnectTarget = nil } }),
            presenting: model.disconnectTarget
        ) { target in
            Button(String(localized: "Disconnect"), role: .destructive) { Task { await model.disconnect(target) } }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text(disconnectMessage(target))
        }
        .sheet(item: $model.upworkApp) { app in
            UpworkConnectionSheet(model: model, app: app)
                .macSheetFrame()
        }
        .sheet(item: $model.googleApp) { _ in
            GoogleWorkspaceSheet(model: model.google)
                .macSheetFrame()
        }
        .sheet(item: $model.keyRequest) { request in
            CapabilityKeyEntrySheet(model: model, request: request)
                .macSheetFrame()
        }
        .sheet(item: $model.credentialPrompt) { prompt in
            CredentialSheet(prompt: prompt, botName: model.botName) { values in
                Task { await model.connect(prompt.app, credentials: values) }
            }
            .macSheetFrame()
        }
    }

    private func customConnectorPanel(_ connector: CustomConnectorModel) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { Task { await model.leaveCustomConnector() } } label: { // nav-chrome: ok
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PalTokens.textPrimary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Back"))
                .accessibilityLabel(Text("Back"))
                .accessibilityIdentifier("customConnectorBackButton")
                Spacer()
            }
            .padding(.leading, 29)
            .padding(.trailing, 38)
            .padding(.top, 47)
            .frame(height: 71, alignment: .top)
            CustomConnectorForm(model: connector, style: .mac) { Task { await model.leaveCustomConnector() } }
        }
        .preference(key: MacPanelCloseIdentifierKey.self, value: "customConnectorCloseButton")
    }

    private var listPanel: some View {
        VStack(spacing: 0) {
            header
            if onCatalog {
                searchField.padding(.horizontal, 29).padding(.top, 17)
                chips.padding(.top, 11.5)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if onCatalog { catalogContent } else { yourPluginsContent }
                    Button("Add a custom connector") { model.addCustomConnector() }
                        .buttonStyle(.palPill)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                        .accessibilityIdentifier("addCustomConnectorButton")
                }
                .padding(.horizontal, 29)
                .padding(.top, onCatalog ? 25.5 : 20)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.never)
        }
    }

    @ViewBuilder
    var searchResults: some View {
        let apps = model.searchedApps
        let skills = model.searchedSkills
        if apps.isEmpty, skills.isEmpty {
            Text("No matches")
                .foregroundStyle(PalTokens.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
                .accessibilityIdentifier("connectAppsNoMatches")
        }
        if !apps.isEmpty {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                ForEach(apps) { appRow($0) }
            }
        }
        if !skills.isEmpty {
            section(title: String(localized: "Skills"), identifier: "connectAppsSection-skills", viewAll: nil) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                    ForEach(skills) { skill in
                        tileRow(title: skill.name, summary: skill.category, identifier: "skill-\(skill.id)", trailing: nil, busy: false) { MacAppTile() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var yourPluginsContent: some View {
        let apps = model.connectedApps
        if apps.isEmpty {
            Text("Nothing connected yet")
                .foregroundStyle(PalTokens.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
                .accessibilityIdentifier("yourPluginsEmpty")
        }
        if !apps.isEmpty {
            section(title: String(localized: "Apps"), identifier: "yourPluginsSection-apps", viewAll: nil) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                    ForEach(apps) { app in
                        tileRow(
                            title: app.name, summary: app.summary, identifier: "yourPlugin-\(app.id)",
                            trailing: MacRowAction(title: String(localized: "Disconnect"), prominent: false) { model.disconnectTarget = .app(app) },
                            busy: model.busy.contains(app.id), status: ConnectAppStatus(app.state).row
                        ) { icon(for: app) }
                    }
                }
            }
        }
    }

    func appRow(_ app: ConnectApp) -> some View {
        let state = model.cardState(app)
        let action: MacRowAction? = if app.requiresAppSignIn {
            MacRowAction(title: UpworkCardText.actionTitle(state), prominent: state.isReconnect) { model.upworkApp = app }
        } else if app.source == .googleWorkspace {
            MacRowAction(
                title: GoogleWorkspaceText.actionTitle(model.googleRow(app).state),
                prominent: model.googleRow(app).state == .needsAuthorization
            ) { model.googleApp = app }
        } else if case .custom = app.source {
            MacRowAction(title: String(localized: "Manage"), prominent: false) { model.manage(app) }
        } else {
            switch app.state {
            case .disconnected: MacRowAction(title: OtherConnectorCardText.connectTitle(state), prominent: false) { Task { await model.connect(app) } }
            case .needsAuthorization: MacRowAction(title: String(localized: "Authorize"), prominent: true) { Task { await model.connect(app) } }
            case .needsSetup: nil
            case .connected:
                if app.requiresToken {
                    MacRowAction(title: String(localized: "Update token"), prominent: false) { Task { await model.connect(app) } }
                } else {
                    MacRowAction(title: String(localized: "Manage"), prominent: false) { model.manageAccounts(app) }
                }
            }
        }
        return tileRow(
            title: app.name, summary: summary(for: app, state: state),
            identifier: "connectApp-\(app.id)", trailing: action, busy: model.busy.contains(app.id),
            status: ConnectAppStatus(app.source == .googleWorkspace ? model.googleRow(app).state : app.state).row
        ) { icon(for: app) }
    }

    private func summary(for app: ConnectApp, state: ConnectorCardState) -> String {
        if app.requiresAppSignIn { return UpworkCardText.summary(state, fallback: app.summary) }
        if app.source == .googleWorkspace { return GoogleWorkspaceText.summary(model.googleRow(app)) }
        return OtherConnectorCardText.summary(state, fallback: app.summary)
    }

    @ViewBuilder
    private func icon(for app: ConnectApp) -> some View {
        switch app.source {
        case .catalog, .mcp, .custom, .googleWorkspace: MacAppTile()
        }
    }

    private func tileRow<Icon: View>(
        title: String, summary: String, identifier: String, trailing: MacRowAction?, busy: Bool, status: ConnectRowStatus? = nil,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        HStack(spacing: 8) {
            icon()
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(PalTokens.textPrimary)
                    .lineLimit(1)
                if let status { ConnectStatusChip(status) }
            }
            Spacer(minLength: 8)
            if busy {
                ProgressView().controlSize(.small)
            } else if let trailing {
                trailing.view(identifier: "\(identifier)-action")
            }
        }
        .frame(height: 60.5)
        .help(summary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func disconnectMessage(_ target: ConnectDisconnectTarget) -> String {
        String(localized: "\(model.botName) loses access to this app until you connect it again.")
    }
}

struct MacCapabilityRow: View {
    let row: CapabilityRow
    let onSetKey: ((String) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: row.indicator.symbolName)
                .font(.system(size: 16))
                .foregroundStyle(indicatorColor)
                .frame(width: 38)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(row.label)
                        .font(.system(size: 12))
                        .foregroundStyle(PalTokens.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(row.stateWord)
                        .font(.system(size: 11))
                        .foregroundStyle(PalTokens.textSecondary)
                }
                if let reason = row.reason {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(PalTokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let key = row.shownKeyName {
                    Text(key)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(PalTokens.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(PalTokens.chipFill, in: Capsule())
                        .padding(.top, 2)
                }
                if let onSetKey {
                    CapabilitySetKeyButton(row: row, onSelect: onSetKey)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: onSetKey == nil ? .combine : .contain)
        .accessibilityLabel(Text(row.accessibilitySummary))
        .accessibilityIdentifier(row.accessibilityIdentifier)
    }

    private var indicatorColor: Color {
        switch row.indicator {
        case .on: PalTokens.toggleOn
        case .limited: PalTokens.textPrimary
        case .off, .unavailable: PalTokens.textTertiary
        }
    }
}

struct MacAppTile: View {
    var size: CGFloat = 38
    var radius: CGFloat = 10
    var glyphSize: CGFloat = 16

    var body: some View {
        glyph
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .accessibilityHidden(true)
    }

    private var glyph: some View {
        Image(systemName: "puzzlepiece.extension")
            .font(.system(size: glyphSize))
            .foregroundStyle(PalTokens.textPrimary)
            .frame(width: size, height: size)
            .background(PalTokens.control)
    }
}
#endif
