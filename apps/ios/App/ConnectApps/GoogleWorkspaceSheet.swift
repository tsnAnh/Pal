import PalAuth
import PalConnect
import PalDesign
import PalDevice
import PalProtocol
import SwiftUI

enum GoogleWorkspaceText {
    static let reads = String(localized: "Your bot can use the Google services you choose below, for the account you sign in with.")
    static let writes = String(localized: "Reading is the default. Turn on Allow changes only for services where your bot may also create, edit or send.")
    static let contacts = String(localized: "Contacts are read only.")
    static let anywhere = String(localized: "Your Pal keeps the sign-in, so every device and bot can use it. This app never holds it.")
    static let setupPurpose = String(localized: "Create a Desktop app client in your Google account, then paste its client ID and client secret. They are saved on your Pal and can't be read back.")

    static func actionTitle(_ state: ConnectAppState) -> String {
        switch state {
        case .disconnected: String(localized: "Connect")
        case .connected: String(localized: "Manage")
        case .needsAuthorization: String(localized: "Sign in again")
        }
    }

    static func summary(_ app: ConnectApp) -> String {
        guard app.state == .needsAuthorization, let reason = app.authReason else { return app.summary }
        return reason
    }
}

private struct GoogleAuthTracking: ViewModifier {
    let model: GoogleWorkspaceModel

    @Environment(ServiceSignInCenter.self) private var signIn

    private var pending: ServiceSignInReason? { signIn.pendingReason(for: GoogleWorkspaceCatalog.serviceID) }

    func body(content: Content) -> some View {
        content
            .onChange(of: pending, initial: true) { _, reason in model.noteAuthRequired(reason) }
            .onChange(of: signIn.lastResolution) { _, resolution in
                guard let resolution, resolution.service == GoogleWorkspaceCatalog.serviceID, resolution.outcome == .signedIn else { return }
                Task { await model.reloadAfterSignIn() }
            }
    }
}

extension View {
    func googleAuthTracking(_ model: GoogleWorkspaceModel) -> some View {
        modifier(GoogleAuthTracking(model: model))
    }
}

struct GoogleWorkspaceSheet: View {
    let model: GoogleWorkspaceModel

    @Environment(\.dismiss) private var dismiss
    @State private var confirmsRemoveSetup = false

    private var state: GoogleWorkspaceCardState { model.cardState }

    var body: some View {
        SheetChrome(
            title: GoogleWorkspaceCatalog.name,
            accessibilityIdentifier: "googleWorkspace",
            leadingAccessibilityIdentifier: "googleWorkspaceDone",
            onLeading: { dismiss() },
            content: {
                ScrollView {
                    VStack(alignment: .leading, spacing: PalMetrics.cardGap) {
                        SectionCaption(String(localized: "Status"), accessibilityIdentifier: "googleStatusCaption")
                        GroupedCard(accessibilityIdentifier: "googleStatus") {
                            SettingsRow(title: state.summary, accessibilityIdentifier: "googleStatusRow")
                        }
                        if model.isSigningIn {
                            pasteEntry
                        } else if model.needsClient {
                            clientEntry
                        } else {
                            scopes
                            actions
                        }
                    }
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
            }
        )
        .task { await model.load() }
        .onDisappear { Task { await model.cancelSignIn() } }
        .alert(String(localized: "Remove Google setup?"), isPresented: $confirmsRemoveSetup) {
            Button(String(localized: "Remove setup"), role: .destructive) { Task { await model.signOut(removeSetup: true) } }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("This signs you out and removes the saved Google client. You will need to set it up again to sign in.")
        }
    }

    private var pasteEntry: some View {
        PasteAddressEntry(
            state: model.secretState,
            identifiers: SecretEntryIdentifiers(
                field: "google-paste-field", submit: "google-paste-submit", cancel: "google-paste-cancel", status: "google-paste-status"
            ),
            onSubmit: { value in Task { await model.submitPasted(value) } },
            onReopen: { model.reopenSignIn() },
            onCancel: { Task { await model.cancelSignIn() } }
        )
        .padding(.horizontal, 4)
    }

    private var clientEntry: some View {
        let isID = model.clientStep == .clientID
        return SecretEntryView(
            connectorName: GoogleWorkspaceCatalog.name,
            accountLabel: isID ? String(localized: "Step 1 of 2") : String(localized: "Step 2 of 2"),
            purpose: GoogleWorkspaceText.setupPurpose,
            fieldLabel: isID ? String(localized: "Client ID") : String(localized: "Client secret"),
            submitTitle: isID ? String(localized: "Next") : String(localized: "Save"),
            state: model.secretState,
            identifiers: SecretEntryIdentifiers(
                field: "google-client-field", submit: "google-client-submit", cancel: "google-client-cancel", status: "google-client-status"
            ),
            onSubmit: { value in Task { await model.submitClientField(value) } },
            onCancel: { if isID { dismiss() } else { model.restartClientEntry() } }
        )
        .id(model.clientStep)
        .padding(.horizontal, PalMetrics.screenMargin)
    }

    @ViewBuilder
    private var scopes: some View {
        SectionCaption(String(localized: "Read"), accessibilityIdentifier: "googleReadCaption")
        GroupedCard(accessibilityIdentifier: "googleReadScopes") {
            ForEach(GoogleService.allCases, id: \.self) { service in
                SettingsRow.toggle(
                    service.displayName,
                    isOn: Binding(get: { model.readBinding(service) }, set: { model.setRead(service, $0) }),
                    accessibilityIdentifier: "googleRead-\(service.rawValue)"
                )
            }
        }
        SectionCaption(String(localized: "Allow changes"), accessibilityIdentifier: "googleWriteCaption")
        GroupedCard(accessibilityIdentifier: "googleWriteScopes") {
            ForEach(GoogleService.allCases.filter(\.hasWriteOptIn), id: \.self) { service in
                SettingsRow.toggle(
                    service.displayName,
                    isOn: Binding(get: { model.writeBinding(service) }, set: { model.setWrite(service, $0) }),
                    accessibilityIdentifier: "googleWrite-\(service.rawValue)"
                )
                .disabled(!model.selection.allowsWrite(service))
            }
        }
        CardFootnote(GoogleWorkspaceText.writes, accessibilityIdentifier: "googleWrites")
        CardFootnote(GoogleWorkspaceText.contacts, accessibilityIdentifier: "googleContacts")
        CardFootnote(GoogleWorkspaceText.anywhere, accessibilityIdentifier: "googleAnywhere")
    }

    @ViewBuilder
    private var actions: some View {
        GroupedCard(accessibilityIdentifier: "googleSignIn") {
            SettingsRow(title: signInTitle, accessibilityIdentifier: "googleSignInRow") { Task { await model.startSignIn() } }
                .disabled(model.isWorking || model.selection.isEmpty)
        }
        if model.status != nil {
            GroupedCard(accessibilityIdentifier: "googleRefresh") {
                SettingsRow(title: String(localized: "Check with Google"), accessibilityIdentifier: "googleRefreshRow") { Task { await model.refresh() } }
                    .disabled(model.isWorking)
            }
        }
        if state.isSignedIn || isReauth {
            GroupedCard(accessibilityIdentifier: "googleSignOut") {
                SettingsRow.destructive(String(localized: "Sign out"), accessibilityIdentifier: "googleSignOutRow") {
                    Task { await model.signOut(removeSetup: false) }
                }
                .disabled(model.isWorking)
            }
        }
        if model.status.map({ $0.state != .notConfigured }) == true {
            GroupedCard(accessibilityIdentifier: "googleRemoveSetup") {
                SettingsRow.destructive(String(localized: "Remove setup"), accessibilityIdentifier: "googleRemoveSetupRow") {
                    confirmsRemoveSetup = true
                }
                .disabled(model.isWorking)
            }
        }
    }

    private var isReauth: Bool {
        if case .needsReauth = state { return true }
        return false
    }

    private var signInTitle: String {
        switch state {
        case .signedIn, .needsReauth: String(localized: "Sign in again")
        case .failed: String(localized: "Try again")
        case .notConfigured, .notSignedIn, .signingIn: String(localized: "Sign in with Google")
        }
    }
}
