import PalBotProfile
import PalDesign
import SwiftUI

enum GitHubTokenCopy {
    static let title = "GitHub for this machine"
    static let rowSubtitle = "Used by gh and the faker-kit tools on this host"
    static let setup = "One sign-in serves every bot on this host. Pal never sees the token."
    static let registration = "Register once: GitHub Settings, Developer settings, OAuth Apps, New. Name: Pal. Homepage and callback: any URL. Tick Enable Device Flow. Copy the client ID and paste it here. If your organization restricts third-party apps, an owner must approve Pal."
    static let developersURL = URL(string: "https://github.com/settings/developers")!
}

struct GitHubTokenScreen: View {
    let hub: SettingsHub
    let back: () -> Void

    @State private var model: GitHubTokenModel
    @State private var showingSignIn = false
    @State private var clientID = ""

    init(hub: SettingsHub, back: @escaping () -> Void) {
        self.hub = hub
        self.back = back
        let connection = hub.connection
        let gateway = BotsGateway { method, params in try await connection.rpc(method, params) }
        _model = State(initialValue: GitHubTokenModel(client: GitHubTokenClient(gateway: gateway)))
    }

    var body: some View {
        SettingsPage(title: GitHubTokenCopy.title, identifier: "githubTokenScreen", back: back) {
            VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
                GroupedCard(accessibilityIdentifier: "githubTokenCard") {
                    SettingsRow.value(
                        GitHubTokenCopy.title, value: model.headline, subtitle: model.status?.detail,
                        accessibilityIdentifier: "githubTokenState")
                    if model.needsClientID {
                        clientIDRows
                    } else if model.canSignIn {
                        SettingsRow(
                            title: model.status?.isSignedIn == true ? "Sign in again" : "Sign in", trailing: .none,
                            accessibilityIdentifier: "githubTokenSignIn", action: signIn)
                    }
                    SettingsRow(
                        title: "Refresh", trailing: .none, accessibilityIdentifier: "githubTokenRefresh",
                        action: { Task { await model.refresh() } })
                    if model.needsClientID {
                        SettingsRow.external("Open GitHub developer settings", accessibilityIdentifier: "githubTokenRegister") {
                            ExternalLink.open(GitHubTokenCopy.developersURL)
                        }
                    }
                }
                if let footnote = model.footnote {
                    CardFootnote(footnote, accessibilityIdentifier: "githubTokenFootnote")
                }
            }
            CardFootnote(
                model.needsClientID ? GitHubTokenCopy.registration : GitHubTokenCopy.setup,
                accessibilityIdentifier: "githubTokenSetup")
        }
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
        .sheet(isPresented: $showingSignIn, onDismiss: { Task { await model.closeSignIn() } }) {
            GitHubSignInCodeSheet(model: model) { showingSignIn = false }
                .macSheetFrame()
        }
    }

    @ViewBuilder
    private var clientIDRows: some View {
        TextField("Client ID", text: $clientID, prompt: Text("OAuth app client ID"))
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .onSubmit { Task { await model.saveClientID(clientID) } }
            .padding(.horizontal, PalMetrics.rowInset)
            .frame(minHeight: PalMetrics.rowMinimumHeight)
            .accessibilityLabel(Text("Client ID"))
            .accessibilityIdentifier("githubTokenClientID")
        SettingsRow(
            title: clientIDTitle, value: clientIDValue, trailing: .none,
            accessibilityIdentifier: "githubTokenClientIDSave", action: { Task { await model.saveClientID(clientID) } })
    }

    private var clientIDTitle: String {
        model.clientIDState == .saving ? "Saving…" : "Save client ID"
    }

    private var clientIDValue: String? {
        switch model.clientIDState {
        case .saved: "Saved"
        case .failed: "Couldn't save"
        case .idle, .saving: nil
        }
    }

    private func signIn() {
        showingSignIn = true
        Task { await model.beginSignIn() }
    }
}

private struct GitHubSignInCodeSheet: View {
    let model: GitHubTokenModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Sign in to GitHub")
                .hermesText(.sheetTitle)
                .foregroundStyle(PalTokens.textPrimary)
            content
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(PalTokens.elevated)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("githubSignInSheet")
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch model.signIn {
        case .starting, nil:
            ProgressView().accessibilityIdentifier("githubSignInStarting")
        case .code(let code):
            VStack(spacing: 16) {
                message("Open GitHub and enter this code to approve Pal.")
                ServiceSignInCodeCard(code: code.userCode).id(code.sessionID)
                PillButton("Open GitHub", kind: .accent, size: .large, accessibilityIdentifier: "githubSignInOpen") {
                    ExternalLink.open(code.verificationURL)
                }
                message("Waiting for approval…")
                closeButton("Cancel")
            }
        case .signedIn(let login):
            message(login.map { "Signed in as \($0)." } ?? "Signed in.")
            closeButton("Done", kind: .accent)
        case .denied:
            message("Sign-in was denied.")
            retryButtons
        case .expired:
            message("That code expired.")
            retryButtons
        case .organizationApproval:
            message("An organization owner must approve Pal in the organization's settings, then sign in again.")
            retryButtons
        case .failed(let text):
            message(text)
            retryButtons
        }
    }

    private var retryButtons: some View {
        VStack(spacing: 8) {
            PillButton("Try again", kind: .accent, size: .large, accessibilityIdentifier: "githubSignInRetry") {
                Task { await model.beginSignIn() }
            }
            closeButton("Close")
        }
    }

    private func closeButton(_ title: String, kind: PillKind = .dimmed) -> some View {
        PillButton(title, kind: kind, size: .large, accessibilityIdentifier: "githubSignInClose", action: close)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .hermesText(.rowSubtitle)
            .foregroundStyle(PalTokens.textSecondary)
            .multilineTextAlignment(.center)
    }
}
