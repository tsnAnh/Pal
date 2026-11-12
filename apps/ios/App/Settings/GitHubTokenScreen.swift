import PalBotProfile
import PalDesign
import PalProtocol
import SwiftUI

enum GitHubTokenCopy {
    static let rowSubtitle = "Used by gh and the faker-kit tools on this host"
    static let setup = "One token serves every bot on this host. It needs the classic scopes repo and workflow; workflow also lets bots update workflow files and merge such pull requests. A fine-grained token on an organization needs the organization's approval. The token is never shown again after you save it."
    static let tokensURL = URL(string: "https://github.com/settings/tokens")!
}

struct GitHubTokenScreen: View {
    let hub: SettingsHub
    let back: () -> Void

    @State private var model: GitHubTokenModel
    @State private var entering = false

    init(hub: SettingsHub, back: @escaping () -> Void) {
        self.hub = hub
        self.back = back
        let connection = hub.connection
        let gateway = BotsGateway { method, params in try await connection.rpc(method, params) }
        _model = State(initialValue: GitHubTokenModel(client: GitHubTokenClient(gateway: gateway)))
    }

    var body: some View {
        SettingsPage(title: "GitHub token", identifier: "githubTokenScreen", back: back) {
            VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
                GroupedCard(accessibilityIdentifier: "githubTokenCard") {
                    SettingsRow.value(
                        "GitHub token for this machine", value: model.headline, subtitle: model.status?.detail,
                        accessibilityIdentifier: "githubTokenState")
                    if model.canSet {
                        SettingsRow(
                            title: model.status?.isSet == true ? "Replace token" : "Set token", trailing: .none,
                            accessibilityIdentifier: "githubTokenSet", action: { open() })
                    }
                    SettingsRow(
                        title: "Refresh", trailing: .none, accessibilityIdentifier: "githubTokenRefresh",
                        action: { Task { await model.refresh() } })
                    SettingsRow.external("Create a token on GitHub", accessibilityIdentifier: "githubTokenCreate") {
                        ExternalLink.open(GitHubTokenCopy.tokensURL)
                    }
                }
                outcome
            }
            CardFootnote(GitHubTokenCopy.setup, accessibilityIdentifier: "githubTokenSetup")
        }
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
        .sheet(isPresented: $entering) {
            GitHubTokenEntrySheet(model: model) { entering = false }
                .presentationDetents([.medium])
                .macSheetFrame()
        }
    }

    @ViewBuilder
    private var outcome: some View {
        if let footnote = model.footnote {
            CardFootnote(footnote, accessibilityIdentifier: "githubTokenFootnote")
        } else if model.setState == .saved {
            CardFootnote("Token saved.", accessibilityIdentifier: "githubTokenSaved")
        }
    }

    private func open() {
        model.resetSetState()
        entering = true
    }
}

private struct GitHubTokenEntrySheet: View {
    let model: GitHubTokenModel
    let close: () -> Void

    private var state: SecretEntryState {
        switch model.setState {
        case .idle: .idle
        case .submitting: .submitting
        case .saved: .success
        case .failed(let text): .failure(text)
        }
    }

    var body: some View {
        SecretEntryView(
            connectorName: "GitHub token",
            accountLabel: "This machine",
            purpose: "Paste a GitHub token with the repo and workflow scopes. It is saved on this host for every bot and can't be read back.",
            fieldLabel: "Token",
            state: state,
            identifiers: SecretEntryIdentifiers(
                field: "githubTokenField", submit: "githubTokenSave", cancel: "githubTokenCancel", status: "githubTokenStatus"),
            onSubmit: { value in Task { await model.set(SecretString(value)) } },
            onCancel: close
        )
        .padding(24)
        .onChange(of: model.setState) { _, new in
            if new == .saved { close() }
        }
    }
}
