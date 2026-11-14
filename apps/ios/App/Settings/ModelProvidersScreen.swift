import PalBotProfile
import PalDesign
import PalDevice
import SwiftUI

struct ModelProvidersScreen: View {
    let hub: SettingsHub
    let back: () -> Void

    @Environment(\.hermesTheme) private var theme
    @State private var model: ModelProvidersModel

    init(hub: SettingsHub, back: @escaping () -> Void) {
        self.hub = hub
        self.back = back
        _model = State(initialValue: hub.modelProvidersModel())
    }

    var body: some View {
        SettingsPage(title: "Model providers", identifier: "modelProvidersScreen", back: back) {
            content
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .tracksProviderSignIns(model)
        .providerRemovalConfirmation(model)
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded && model.loadFailed {
            FailureCard(message: ModelProvidersModel.loadFailureText, identifier: "modelProvidersFailure") {
                Task { await model.load() }
            }
        } else if !model.hasLoaded {
            GroupedCard(accessibilityIdentifier: "modelProvidersLoading") {
                LoadingRow(title: "Model providers", identifier: "modelProvidersLoadingRow")
            }
        } else if model.providers.isEmpty {
            CardFootnote("No model providers are available.", accessibilityIdentifier: "modelProvidersEmpty")
        } else {
            searchField
            let sections = model.sections
            ForEach(sections) { section in
                providerSection(section)
            }
            if sections.isEmpty {
                CardFootnote(ModelProvidersModel.noMatchText, accessibilityIdentifier: "modelProvidersNoMatch")
            }
            CardFootnote(
                model.loadFailed ? ModelProvidersModel.refreshFailureText : ModelProvidersModel.footnoteText,
                accessibilityIdentifier: "modelProvidersFootnote")
        }
    }

    private var searchField: some View {
        TextField("Search providers", text: $model.query)
            .textFieldStyle(.plain)
            .padding(.horizontal, PalMetrics.rowInset)
            .frame(minHeight: PalMetrics.rowMinimumHeight)
            .background(Color(theme.palette.groupedCard), in: Capsule())
            .padding(.horizontal, PalMetrics.screenMargin)
            .accessibilityIdentifier("modelProvidersSearch")
    }

    private func providerSection(_ section: ModelProviderSection) -> some View {
        let group = section.group.rawValue
        return VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
            SectionCaption(section.group.title, accessibilityIdentifier: "modelProviders-\(group)")
            GroupedCard(accessibilityIdentifier: "modelProvidersCard-\(group)") {
                if section.providers.isEmpty {
                    Text(ModelProvidersModel.emptyConnectedText)
                        .hermesText(.rowSubtitle)
                        .foregroundStyle(Color(theme.palette.textSecondary))
                        .padding(.horizontal, PalMetrics.rowInset)
                        .frame(maxWidth: .infinity, minHeight: PalMetrics.rowMinimumHeight, alignment: .leading)
                        .accessibilityIdentifier("modelProvidersEmptyConnected")
                }
                ForEach(section.providers) { provider in
                    providerRows(provider)
                }
                if section.hiddenCount > 0 {
                    SettingsRow(
                        title: "Show \(section.hiddenCount) more", trailing: .none,
                        accessibilityIdentifier: "modelProviders-showMore", action: { model.showsAllOnHost = true })
                } else if section.group == .onHost, model.showsAllOnHost, section.providers.count > 1, model.query.isEmpty {
                    SettingsRow(
                        title: "Show less", trailing: .none,
                        accessibilityIdentifier: "modelProviders-showLess", action: { model.showsAllOnHost = false })
                }
            }
        }
    }

    @ViewBuilder
    private func providerRows(_ provider: ModelProvider) -> some View {
        let key = "modelProvider-\(provider.id)"
        let face = model.presentation(of: provider)
        let failure: String? = if case .failed(let text) = face.status { text } else { nil }
        SettingsRow(
            title: provider.name, subtitle: failure == nil ? face.detail : nil, value: face.stateLabel,
            accessibilityIdentifier: "\(key)-state")
        if let failure {
            Text(failure)
                .hermesText(.rowSubtitle)
                .foregroundStyle(Color(theme.palette.destructive))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PalMetrics.rowInset)
                .padding(.bottom, PalMetrics.rowVerticalPadding)
                .accessibilityIdentifier("\(key)-status")
        }
        if let title = face.primaryAction {
            SettingsRow(
                title: title, trailing: .none, accessibilityIdentifier: "\(key)-action",
                action: { Task { await model.signIn(provider) } }
            )
            .disabled(model.isWorking(provider.id))
        }
        if face.canRemove {
            SettingsRow.destructive("Remove", accessibilityIdentifier: "\(key)-remove") { model.pendingRemoval = provider }
                .disabled(model.isWorking(provider.id))
        }
        if face.canEditAddress {
            addressRows(provider, key: key)
        }
    }

    @ViewBuilder
    private func addressRows(_ provider: ModelProvider, key: String) -> some View {
        TextField(
            "Address",
            text: Binding(get: { model.address(for: provider) }, set: { model.setAddress($0, for: provider) }),
            prompt: Text(provider.defaultBaseURL ?? "Address")
        )
        .textFieldStyle(.plain)
        .urlEntry()
        .submitLabel(.done)
        .onSubmit { Task { await model.saveAddress(provider) } }
        .padding(.horizontal, PalMetrics.rowInset)
        .frame(minHeight: PalMetrics.rowMinimumHeight)
        .disabled(model.isWorking(provider.id))
        .accessibilityLabel(Text("Address"))
        .accessibilityIdentifier("\(key)-address")
        if model.addressIsDirty(for: provider) {
            SettingsRow(
                title: model.status(of: provider.id) == .working(.savingAddress) ? "Saving…" : "Save address", trailing: .none,
                accessibilityIdentifier: "\(key)-address-save", action: { Task { await model.saveAddress(provider) } }
            )
            .disabled(model.isWorking(provider.id))
        }
        if provider.baseURL != nil {
            SettingsRow(
                title: "Use default address", trailing: .none, accessibilityIdentifier: "\(key)-address-default",
                action: { Task { await model.useDefaultAddress(provider) } }
            )
            .disabled(model.isWorking(provider.id))
        }
    }
}

extension SettingsHub {
    @MainActor
    func modelProvidersModel() -> ModelProvidersModel {
        let connection = connection
        let profile = roster.bots.first(where: \.isDefault)?.name
        let gateway = BotsGateway { method, params in try await connection.rpc(method, params) }
        return ModelProvidersModel(client: ModelProvidersClient(gateway: gateway, profile: profile), surfaces: connection.surfaces)
    }
}

private struct ProviderSignInTracking: ViewModifier {
    let model: ModelProvidersModel

    @Environment(ServiceSignInCenter.self) private var signIn

    func body(content: Content) -> some View {
        content.onChange(of: signIn.lastResolution) { _, resolution in
            guard let resolution else { return }
            Task {
                await model.signInResolved(
                    requestID: resolution.requestID, service: resolution.service, outcome: resolution.outcome, reason: resolution.reason)
            }
        }
    }
}

private struct ProviderRemovalConfirmation: ViewModifier {
    let model: ModelProvidersModel

    func body(content: Content) -> some View {
        content.confirmationDialog(
            model.pendingRemoval.map { "Remove \($0.name)?" } ?? "Remove this provider?",
            isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: model.pendingRemoval
        ) { provider in
            Button("Remove", role: .destructive) { Task { await model.remove(provider) } }
                .accessibilityIdentifier("modelProviderRemoveConfirm")
            Button("Cancel", role: .cancel) { model.pendingRemoval = nil }
        } message: { provider in
            Text(
                provider.scope == .account
                    ? "This sign-in is shared by all your bots. Bots that use \(provider.name) stop working until you connect it again."
                    : "Bots that use \(provider.name) stop working until you connect it again.")
        }
    }
}

extension View {
    func tracksProviderSignIns(_ model: ModelProvidersModel) -> some View {
        modifier(ProviderSignInTracking(model: model))
    }

    func providerRemovalConfirmation(_ model: ModelProvidersModel) -> some View {
        modifier(ProviderRemovalConfirmation(model: model))
    }
}
