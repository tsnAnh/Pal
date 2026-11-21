import PalBotProfile
import PalConnect
import PalDesign
import PalProtocol
import SwiftUI

struct ConnectAppsScreen: View {
    @State var model: ConnectAppsModel
    let close: () -> Void

    @Environment(\.scenePhase) private var scenePhase

    init(model: ConnectAppsModel, close: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.close = close
    }

    var body: some View {
        chrome
            .task { await model.start() }
            .googleSignInReload(model)
            .onDisappear { Task { await model.stop() } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.devices.refresh() } }
            }
            .modifier(ConnectAppsPresentations(model: model))
            .modifier(T3CodeSheet(model: model))
            .modifier(DiscordFlowSheet(model: model))
            .modifier(GoogleAdsFlowSheet(model: model))
    }

    @ViewBuilder
    private var chrome: some View {
        #if os(macOS)
        if let connector = model.customConnector {
            customConnectorChrome(connector)
        } else {
            listChrome
        }
        #else
        ConnectAppsPhoneRoot(model: model, close: close)
        #endif
    }

    #if os(macOS)
    private var listChrome: some View {
        VStack(spacing: 0) {
            switch model.navigation.screen {
            case .apps:
                ConnectAppsMacHeader(model: model)
                ConnectAppsList(model: model)
            case .installed:
                ConnectAppsMacInstalled(model: model)
            }
        }
        .preference(key: MacPanelCloseKey.self, value: MacPanelCloseOverride(hidden: !model.navigation.showsPanelClose))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectApps")
    }

    private func customConnectorChrome(_ connector: CustomConnectorModel) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: MacMetrics.topBarHeight)
            CustomConnectorForm(model: connector, style: .mac) { Task { await model.leaveCustomConnector() } }
        }
        .overlay(alignment: .topLeading) {
            SheetGlassButton(leading: .back, clear: true, accessibilityIdentifier: "customConnectorBackButton") {
                Task { await model.leaveCustomConnector() }
            }
            .padding(.top, PalMetrics.macPanelCloseTopInset)
            .padding(.leading, PalMetrics.macPanelCloseLeadingInset)
        }
        .preference(key: MacPanelCloseKey.self, value: MacPanelCloseOverride(hidden: true))
    }
    #endif
}

private struct ConnectAppsPresentations: ViewModifier {
    @Bindable var model: ConnectAppsModel

    private func mcpSignInSheet(_ controller: McpSignInController) -> some View {
        McpSignInSheet(controller: controller) { model.mcpSignIn = nil }
    }

    func body(content: Content) -> some View {
        content
            .macAlert(item: $model.notice) { notice in
                MacDialogContent(
                    notice.title,
                    message: notice.message,
                    actions: [MacDialogAction(String(localized: "OK"), role: .cancel)]
                )
            }
            .macAlert(item: $model.disconnectTarget) { target in
                MacDialogContent(
                    String(localized: "Disconnect \(target.name)?"),
                    message: String(localized: "\(model.botName) loses access to this app until you connect it again."),
                    actions: [
                        MacDialogAction(String(localized: "Disconnect"), role: .destructive) { Task { await model.disconnect(target) } },
                        MacDialogAction(String(localized: "Cancel"), role: .cancel),
                    ]
                )
            }
            .macSheet(isPresented: $model.showsSkills) {
                SkillsCatalogSheet(model: model.makeSkillsModel(), botName: model.botName) { model.showsSkills = false }
            }
            .macSheet(item: $model.mcpSignIn, onDismiss: { Task { await model.reload() } }, content: mcpSignInSheet)
            .sheet(isPresented: $model.showsSlackPicker) {
                SlackBotChoice(model: model.slack, wizard: model.slackWizard) { model.closeSlackPicker() }
                    .macSheetFrame()
            }
            .modifier(OwnerSetupSheet(model: model))
            .macSheet(item: $model.keyRequest) { request in
                CapabilityKeyEntrySheet(model: model, request: request)
                    .presentationDetents([.medium])
            }
            .sheet(item: $model.credentialPrompt) { prompt in
                CredentialSheet(prompt: prompt, botName: model.botName) { values in
                    Task { await model.connect(prompt.app, credentials: values) }
                }
                .macSheetFrame()
            }
    }
}

private struct OwnerSetupSheet: ViewModifier {
    @Bindable var model: ConnectAppsModel

    func body(content: Content) -> some View {
        content.sheet(
            item: $model.ownerSetup,
            onDismiss: { Task { await model.reload() } },
            content: { setup in OwnerSetupView(model: setup).macSheetFrame(readable: true) }
        )
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
