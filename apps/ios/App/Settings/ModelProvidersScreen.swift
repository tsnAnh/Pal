import PalBotProfile
import PalDesign
import PalDevice
import SwiftUI

struct ModelProvidersScreen: View {
    let hub: SettingsHub
    let back: () -> Void

    @Environment(ServiceSignInCenter.self) private var signIn
    @Environment(\.hermesTheme) private var theme
    @State private var model: ModelProvidersModel

    init(hub: SettingsHub, back: @escaping () -> Void) {
        self.hub = hub
        self.back = back
        let connection = hub.connection
        let profile = hub.roster.bots.first(where: \.isDefault)?.name
        let gateway = BotsGateway { method, params in try await connection.rpc(method, params) }
        _model = State(initialValue: ModelProvidersModel(client: ModelProvidersClient(gateway: gateway, profile: profile)))
    }

    var body: some View {
        SettingsPage(title: "Model providers", identifier: "modelProvidersScreen", back: back) {
            content
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .onChange(of: signIn.lastResolution) { _, resolution in
            guard let resolution else { return }
            Task {
                await model.signInResolved(
                    requestID: resolution.requestID, service: resolution.service, outcome: resolution.outcome, reason: resolution.reason)
            }
        }
        .confirmationDialog(
            "Remove this provider?",
            isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: model.pendingRemoval
        ) { provider in
            Button("Remove", role: .destructive) { Task { await model.remove(provider) } }
                .accessibilityIdentifier("modelProviderRemoveConfirm")
            Button("Cancel", role: .cancel) { model.pendingRemoval = nil }
        } message: { provider in
            Text("\(provider.name) stops working until you set it up again.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded && model.loadFailed {
            FailureCard(message: "Couldn't load your model providers.", identifier: "modelProvidersFailure") {
                Task { await model.load() }
            }
        } else if !model.hasLoaded {
            GroupedCard(accessibilityIdentifier: "modelProvidersLoading") {
                LoadingRow(title: "Model providers", identifier: "modelProvidersLoadingRow")
            }
        } else if model.providers.isEmpty {
            CardFootnote("No model providers are available.", accessibilityIdentifier: "modelProvidersEmpty")
        } else {
            ForEach(model.providers) { provider in
                providerSection(provider)
            }
            CardFootnote(
                model.loadFailed ? "Couldn't refresh. Pull to try again." : "Keys are never shown after you save them.",
                accessibilityIdentifier: "modelProvidersFootnote")
        }
    }

    private func providerSection(_ provider: ModelProvider) -> some View {
        let key = "modelProvider-\(provider.id)"
        return VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
            GroupedCard(accessibilityIdentifier: key) {
                SettingsRow.value(
                    provider.name, value: stateText(provider), subtitle: subtitle(provider), accessibilityIdentifier: "\(key)-state")
                if let title = actionTitle(provider) {
                    SettingsRow(
                        title: title, trailing: .none, accessibilityIdentifier: "\(key)-action",
                        action: { Task { await model.signIn(provider) } }
                    )
                    .disabled(model.isWorking(provider.id))
                }
                if provider.canRemove {
                    SettingsRow.destructive("Remove", accessibilityIdentifier: "\(key)-remove") { model.pendingRemoval = provider }
                        .disabled(model.isWorking(provider.id))
                }
                if provider.baseURLEditable {
                    addressRows(provider, key: key)
                }
            }
            statusLine(provider, key: key)
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

    @ViewBuilder
    private func statusLine(_ provider: ModelProvider, key: String) -> some View {
        switch model.status(of: provider.id) {
        case .idle:
            EmptyView()
        case .working(let work):
            CardFootnote(workText(work), accessibilityIdentifier: "\(key)-status")
        case .succeeded(let text):
            CardFootnote(text, accessibilityIdentifier: "\(key)-status")
        case .cancelled:
            CardFootnote("Cancelled. Nothing changed.", accessibilityIdentifier: "\(key)-status")
        case .failed(let text):
            Text(text)
                .hermesText(.rowSubtitle)
                .foregroundStyle(Color(theme.palette.destructive))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PalMetrics.screenMargin + PalMetrics.rowInset - 3)
                .accessibilityIdentifier("\(key)-status")
        }
    }

    private func workText(_ work: ModelProvidersModel.Work) -> String {
        switch work {
        case .signingIn: "Waiting for you to finish in the sign-in window…"
        case .removing: "Removing…"
        case .savingAddress: "Saving…"
        }
    }

    private func stateText(_ provider: ModelProvider) -> String {
        switch provider.state {
        case .set: "Set"
        case .notSet: "Not set"
        case .expired: "Expired"
        case .unsupported: "Not supported here"
        case .unknown: "Unknown"
        }
    }

    private func subtitle(_ provider: ModelProvider) -> String? {
        let primary: String? = switch provider.state {
        case .unsupported: provider.reason
        case .expired: provider.reason ?? "It stopped working. Set it up again."
        case .set, .notSet, .unknown: nil
        }
        let shared: String? = provider.scope == .account ? "Shared by all your bots" : nil
        let lines = [primary, shared].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func actionTitle(_ provider: ModelProvider) -> String? {
        guard provider.canSignIn else { return nil }
        if model.status(of: provider.id) == .working(.signingIn) { return "Waiting for sign-in…" }
        switch (provider.kind, provider.state) {
        case (.apiKey, .set), (.apiKey, .expired): return "Replace key"
        case (.apiKey, _): return "Set key"
        case (.deviceCode, .set), (.deviceCode, .expired): return "Sign in again"
        case (.deviceCode, _): return "Sign in"
        case (.unsupported, _), (.unknown, _): return nil
        }
    }
}
