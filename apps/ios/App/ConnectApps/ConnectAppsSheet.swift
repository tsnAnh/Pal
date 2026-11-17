import PalBotProfile
import PalConnect
import PalDesign
import PalDevice
import PalProtocol
import SwiftUI

struct ConnectAppsSheet: View {
    @State var model: ConnectAppsModel
    let close: () -> Void

    @Environment(\.hermesTheme) var theme
    @Environment(\.scenePhase) private var scenePhase

    static let rowsPerSectionInAll = 4
    static let cardInset: CGFloat = 14

    init(model: ConnectAppsModel, close: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.close = close
    }

    var onCatalog: Bool { model.page == .catalog }

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
        .sheet(item: $model.upworkApp) { app in
            UpworkConnectionSheet(model: model, app: app)
                .macSheetFrame()
        }
        .sheet(item: $model.oauthClientSheet) { sheet in
            OAuthClientSheet(model: sheet)
                .macSheetFrame()
        }
        .sheet(item: $model.setupGuideSheet) { guide in
            SetupGuideView(model: guide)
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

    func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.vertical, 2)
            .kanbanGlass(RoundedRectangle(cornerRadius: PalMetrics.tileRadius, style: .continuous))
            .padding(.horizontal, PalMetrics.screenMargin)
    }

    private func disconnectMessage(_ target: ConnectDisconnectTarget) -> String {
        "\(model.botName) loses access to this app until you connect it again."
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

struct CapabilityListRow: View {
    let row: CapabilityRow
    let onSetKey: ((String) -> Void)?

    @Environment(\.hermesTheme) var theme

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
