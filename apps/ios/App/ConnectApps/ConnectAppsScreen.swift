import PalBotProfile
import PalConnect
import PalDesign
import PalProtocol
import SwiftUI

struct ConnectAppsScreen: View {
    @State var model: ConnectAppsModel
    let close: () -> Void

    @Environment(\.hermesTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase

    init(model: ConnectAppsModel, close: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.close = close
    }

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
        .modifier(ConnectAppsPresentations(model: model))
        .modifier(T3CodeSheet(model: model))
        .modifier(DiscordFlowSheet(model: model))
    }

    @ViewBuilder
    private var listChrome: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Text("Connect Apps")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(PalTokens.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .padding(.horizontal, PalMetrics.cardGap)
            .frame(height: MacMetrics.topBarHeight)
            ConnectAppsList(model: model)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectApps")
        #else
        SheetChrome(
            title: String(localized: "Connect Apps"),
            titleAlignment: .afterLeadingButton,
            accessibilityIdentifier: "connectApps",
            onLeading: close,
            trailing: { EmptyView() },
            content: { ConnectAppsList(model: model) }
        )
        #endif
    }

    @ViewBuilder
    private func customConnectorChrome(_ connector: CustomConnectorModel) -> some View {
        #if os(macOS)
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
            .padding(.horizontal, PalMetrics.cardGap)
            .frame(height: MacMetrics.topBarHeight)
            CustomConnectorForm(model: connector, style: .mac) { Task { await model.leaveCustomConnector() } }
        }
        .preference(key: MacPanelCloseIdentifierKey.self, value: "customConnectorCloseButton")
        #else
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
        #endif
    }
}

private struct ConnectAppsPresentations: ViewModifier {
    @Bindable var model: ConnectAppsModel

    private func mcpSignInSheet(_ controller: McpSignInController) -> some View {
        McpSignInSheet(controller: controller) { model.mcpSignIn = nil }
            .macSheetFrame()
    }

    func body(content: Content) -> some View {
        content
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
            } message: { _ in
                Text("\(model.botName) loses access to this app until you connect it again.")
            }
            .sheet(isPresented: $model.showsSkills) {
                SkillsCatalogSheet(model: model.makeSkillsModel(), botName: model.botName) { model.showsSkills = false }
                    .macSheetFrame()
            }
            .sheet(item: $model.mcpSignIn, onDismiss: { Task { await model.reload() } }, content: mcpSignInSheet)
            .sheet(isPresented: $model.showsSlackPicker) {
                SlackBotChoice(model: model.slack, wizard: model.slackWizard) { model.closeSlackPicker() }
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
            .sheet(
                item: $model.pastingApp,
                onDismiss: { Task { await model.cancelPaste() } },
                content: { app in OtherConnectorPasteSheet(model: model, app: app).macSheetFrame() }
            )
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
}

struct CredentialSheet: View {
    let prompt: CredentialPrompt
    let botName: String
    let submit: ([String: String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]

    private var pending: String? { prompt.keys.first { values[$0] == nil } }

    private func purpose(for key: String) -> String {
        if !prompt.app.setup.isEmpty { return prompt.app.setup }
        return String(localized: "Paste the key for \(key). It is saved for \(botName) only and can't be read back.")
    }

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
                        purpose: purpose(for: key),
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
