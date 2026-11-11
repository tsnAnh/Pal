#if os(macOS)
import HermesConnect
import HermesDesign
import SwiftUI

struct MacConnectApps: View {
    @State private var model: ConnectAppsModel

    @Environment(\.scenePhase) private var scenePhase

    private static let rowsPerSectionInAll = 6
    private let columns = [GridItem(.flexible(), spacing: 30), GridItem(.flexible(), spacing: 30)]

    init(model: ConnectAppsModel) {
        _model = State(initialValue: model)
    }

    private var onCatalog: Bool { model.page == .catalog }

    var body: some View {
        VStack(spacing: 0) {
            header
            if onCatalog {
                searchField.padding(.horizontal, 29).padding(.top, 17)
                chips.padding(.top, 11.5)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if onCatalog { catalogContent } else { yourPluginsContent }
                }
                .padding(.horizontal, 29)
                .padding(.top, onCatalog ? 25.5 : 20)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.never)
            Button("Add a custom connector") { model.addCustomConnector() }
                .buttonStyle(.palPill)
                .padding(.horizontal, 29)
                .padding(.vertical, 14)
                .accessibilityIdentifier("addCustomConnectorButton")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectApps")
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
        .sheet(item: $model.customConnector) { connector in
            CustomConnectorSheet(model: connector) { model.customConnector = nil }
                .macSheetFrame()
        }
        .sheet(item: $model.credentialPrompt) { prompt in
            CredentialSheet(prompt: prompt) { values in
                Task { await model.connect(prompt.app, credentials: values) }
            }
            .macSheetFrame()
        }
    }

    private var header: some View {
        HStack {
            if onCatalog {
                Text("Connect Apps")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(PalTokens.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            } else {
                Button { model.page = .catalog } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Your plugins").font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(PalTokens.textPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("connectAppsBack")
            }
            Spacer()
            if onCatalog { connectedCount }
        }
        .padding(.leading, 29)
        .padding(.trailing, 38)
        .padding(.top, 47)
        .frame(height: 71, alignment: .top)
    }

    private var connectedCount: some View {
        Button { model.page = .yourPlugins } label: {
            HStack(spacing: 6) {
                stackedIcons
                HStack(spacing: 4) {
                    Text("\(model.connectedCount) connected")
                        .font(.system(size: 11))
                        .foregroundStyle(PalTokens.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(PalTokens.textSecondary)
                }
            }
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(model.connectedCount) connected"))
        .accessibilityIdentifier("connectedCountButton")
    }

    private var stackedIcons: some View {
        HStack(spacing: -3) {
            ForEach(Array(model.connectedApps.prefix(4).enumerated()), id: \.element.id) { index, app in
                MacAppTile(url: app.iconURL, size: 16, radius: 4, glyphSize: 8)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(PalTokens.elevated, lineWidth: 1))
                    .zIndex(Double(-index))
            }
        }
        .accessibilityHidden(true)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(PalTokens.textSecondary)
            TextField("Search across apps and skills", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .accessibilityIdentifier("connectAppsSearch")
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .palGlass(RoundedRectangle(cornerRadius: 10, style: .continuous), interactive: false)
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(model.chips, id: \.self) { chip in chipButton(chip) }
            }
            .padding(.horizontal, 29)
        }
        .scrollIndicators(.never)
        .frame(height: 25)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectAppsChips")
    }

    private func chipTitle(_ id: String) -> String {
        switch id {
        case ConnectChip.all: String(localized: "All")
        case ConnectChip.iphone: String(localized: "This Mac")
        default: id
        }
    }

    private func chipButton(_ id: String) -> some View {
        let selected = model.selection == id && model.trimmedQuery.isEmpty
        return Button { model.selection = id; model.query = "" } label: {
            Text(chipTitle(id))
                .font(.system(size: 12))
                .foregroundStyle(selected ? PalTokens.inverseText : PalTokens.textSecondary)
                .padding(.horizontal, 9)
                .frame(height: 25)
                .background(selected ? PalTokens.inverseFill : PalTokens.chipFill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("connectAppsChips-\(id)")
    }

    @ViewBuilder
    private var catalogContent: some View {
        switch model.phase {
        case .loading where model.catalog.apps.isEmpty:
            ProgressView().frame(maxWidth: .infinity).padding(.top, 60).accessibilityIdentifier("connectAppsLoading")
        case .unavailable:
            VStack(spacing: 14) {
                Text("Couldn't load apps").foregroundStyle(PalTokens.textSecondary)
                Button("Try again") { Task { await model.reload() } }
                    .buttonStyle(.palPill)
                    .accessibilityIdentifier("connectAppsRetry")
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
            .accessibilityIdentifier("connectAppsUnavailable")
        default:
            if !model.trimmedQuery.isEmpty { searchResults } else { selectedSection }
        }
    }

    @ViewBuilder
    private var selectedSection: some View {
        switch model.selection {
        case ConnectChip.all:
            section(title: String(localized: "This Mac"), identifier: "connectAppsSection-iphone", viewAll: { model.selection = ConnectChip.iphone }) {
                deviceGrid
            }
            ForEach(model.catalog.categories, id: \.self) { category in
                section(title: category, identifier: "connectAppsSection-\(category)", viewAll: { model.selection = category }) {
                    appGrid(Array(model.catalog.apps(in: category).prefix(Self.rowsPerSectionInAll)))
                }
            }
        case ConnectChip.iphone:
            section(title: String(localized: "This Mac"), identifier: "connectAppsSectionTitle", viewAll: nil) { deviceGrid }
        case let category:
            section(title: category, identifier: "connectAppsSectionTitle", viewAll: nil) {
                appGrid(model.catalog.apps(in: category))
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let devices = model.searchedDevices
        let apps = model.searchedApps
        let skills = model.searchedSkills
        if devices.isEmpty, apps.isEmpty, skills.isEmpty {
            Text("No matches")
                .foregroundStyle(PalTokens.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
                .accessibilityIdentifier("connectAppsNoMatches")
        }
        if !devices.isEmpty || !apps.isEmpty {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                ForEach(devices, id: \.renderID) { deviceRow($0) }
                ForEach(apps) { appRow($0) }
            }
        }
        if !skills.isEmpty {
            section(title: String(localized: "Skills"), identifier: "connectAppsSection-skills", viewAll: nil) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                    ForEach(skills) { skill in
                        tileRow(title: skill.name, summary: skill.category, identifier: "skill-\(skill.id)", trailing: nil, busy: false) { MacAppTile(url: nil) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var yourPluginsContent: some View {
        let apps = model.connectedApps
        let devices = model.connectedDeviceRows
        if apps.isEmpty, devices.isEmpty {
            Text("Nothing connected yet")
                .foregroundStyle(PalTokens.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
                .accessibilityIdentifier("yourPluginsEmpty")
        }
        if !devices.isEmpty {
            section(title: String(localized: "This Mac"), identifier: "yourPluginsSection-iphone", viewAll: nil) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                    ForEach(devices) { row in
                        tileRow(
                            title: row.title, summary: row.subtitle, identifier: "yourPlugin-device-\(row.id.rawValue)",
                            trailing: MacRowAction(title: String(localized: "Turn off"), prominent: false) { model.disconnectTarget = .device(row) },
                            busy: model.busy.contains("device:\(row.id.rawValue)")
                        ) { DeviceTile(connector: row.id).scaleEffect(0.95).frame(width: 38, height: 38) }
                    }
                }
            }
        }
        if !apps.isEmpty {
            section(title: String(localized: "Apps"), identifier: "yourPluginsSection-apps", viewAll: nil) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                    ForEach(apps) { app in
                        tileRow(
                            title: app.name, summary: app.summary, identifier: "yourPlugin-\(app.id)",
                            trailing: MacRowAction(title: String(localized: "Disconnect"), prominent: false) { model.disconnectTarget = .app(app) },
                            busy: model.busy.contains(app.id)
                        ) { icon(for: app) }
                    }
                }
            }
        }
    }

    private func section<Body: View>(title: String, identifier: String, viewAll: (() -> Void)?, @ViewBuilder content: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PalTokens.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(identifier)
                Spacer()
                if let viewAll {
                    Button("View all", action: viewAll)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(PalTokens.textSecondary)
                        .accessibilityIdentifier("\(identifier)-viewAll")
                }
            }
            content()
        }
    }

    private var deviceGrid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
            ForEach(model.deviceRows, id: \.renderID) { deviceRow($0) }
        }
    }

    private func appGrid(_ apps: [ConnectApp]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
            ForEach(apps) { appRow($0) }
        }
    }

    private func appRow(_ app: ConnectApp) -> some View {
        let action: MacRowAction = if case .custom = app.source {
            MacRowAction(title: String(localized: "Manage"), prominent: false) { model.manage(app) }
        } else {
            switch app.state {
        case .disconnected: MacRowAction(title: String(localized: "Connect"), prominent: false) { Task { await model.connect(app) } }
        case .needsAuthorization: MacRowAction(title: String(localized: "Authorize"), prominent: true) { Task { await model.connect(app) } }
        case .connected: MacRowAction(title: String(localized: "Connected"), checked: true) { model.disconnectTarget = .app(app) }
            }
        }
        return tileRow(
            title: app.name, summary: app.summary, identifier: "connectApp-\(app.id)", trailing: action, busy: model.busy.contains(app.id)
        ) { icon(for: app) }
    }

    private func deviceRow(_ row: DeviceRow) -> some View {
        let action: MacRowAction = switch row.action {
        case .allow: MacRowAction(title: String(localized: "Allow"), prominent: true) { Task { await model.allow(row) } }
        case .allowInSettings: MacRowAction(title: String(localized: "Allow in Settings"), prominent: true) { model.openSettings() }
        case .connected: MacRowAction(title: String(localized: "Connected"), checked: true) { model.disconnectTarget = .device(row) }
        }
        return tileRow(
            title: row.title, summary: row.subtitle, identifier: "deviceConnector-\(row.id.rawValue)", trailing: action,
            busy: model.busy.contains("device:\(row.id.rawValue)")
        ) { DeviceTile(connector: row.id).scaleEffect(0.95).frame(width: 38, height: 38) }
    }

    @ViewBuilder
    private func icon(for app: ConnectApp) -> some View {
        switch app.source {
        case .hosted: MacAppTile(url: app.iconURL)
        case .mcp, .custom: MacAppTile(url: nil)
        }
    }

    private func tileRow<Icon: View>(
        title: String, summary: String, identifier: String, trailing: MacRowAction?, busy: Bool,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        HStack(spacing: 8) {
            icon()
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(PalTokens.textPrimary)
                .lineLimit(1)
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

    private func disconnectVerb(_ target: ConnectDisconnectTarget) -> String {
        if case .device = target { String(localized: "Turn off") } else { String(localized: "Disconnect") }
    }

    private func disconnectMessage(_ target: ConnectDisconnectTarget) -> String {
        switch target {
        case .device: String(localized: "\(model.botName) won't be able to use it until you turn it back on.")
        case .app: String(localized: "\(model.botName) loses access to this app until you connect it again.")
        }
    }
}

private struct MacAppTile: View {
    let url: URL?
    var size: CGFloat = 38
    var radius: CGFloat = 10
    var glyphSize: CGFloat = 16

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if let url {
                RemoteLogo(url: url) { logo in
                    logo.padding(size * 0.18).background(.white)
                } placeholder: {
                    glyph
                }
            } else {
                glyph
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
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

private struct MacRowAction {
    let title: String
    var prominent = false
    var checked = false
    let action: () -> Void


    @MainActor
    @ViewBuilder
    func view(identifier: String) -> some View {
        if checked {
            Button(action: action) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .semibold))
                    Text(title).font(.system(size: 11))
                }
                .foregroundStyle(PalTokens.textTertiary)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(title))
            .accessibilityIdentifier(identifier)
        } else {
            Button(action: action) {
                Text(title).frame(minWidth: 65)
            }
            .buttonStyle(.palPill(height: 22, fontSize: 11, fill: prominent ? PalTokens.toggleOn.opacity(0.7) : nil))
            .accessibilityLabel(Text(title))
            .accessibilityIdentifier(identifier)
        }
    }
}
#endif
