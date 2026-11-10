import HermesDesign
import SwiftUI

struct ConnectionForm: View {
    @Bindable var model: ConnectionModel

    @Environment(\.hermesTheme) private var theme

    private var cardFill: Color { Color(theme.palette.groupedCard) }

    var body: some View {
        Form {
            if !model.isConnected {
                Section("Hermes address") {
                    addressField
                        .urlEntry()
                        .accessibilityIdentifier("baseURLField")
                        .disabled(model.isBusy)
                        .listRowBackground(cardFill)
                    if model.usesPasswordSignIn {
                        credentialFields
                    }
                    Button {
                        Task { await model.signIn() }
                    } label: {
                        HStack {
                            Text("Sign in")
                            if model.isBusy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("signInButton")
                    .listRowBackground(cardFill)
                }
            }
            Section("Status") {
                statusRow
                    .listRowBackground(cardFill)
            }
            if case .connected = model.phase {
                Section {
                    Button("Sign out", role: .destructive) {
                        Task { await model.signOut() }
                    }
                    .foregroundStyle(Color(theme.palette.destructive))
                    .accessibilityIdentifier("signOutButton")
                    .listRowBackground(cardFill)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var credentialFields: some View {
        #if os(macOS)
        TextField("Username", text: $model.username, prompt: Text(verbatim: "Username"))
            .labelsHidden()
            .textContentType(.username)
            .autocorrectionDisabled()
            .disabled(model.isBusy)
            .accessibilityIdentifier("usernameField")
            .listRowBackground(cardFill)
        SecureField("Password", text: $model.password, prompt: Text(verbatim: "Password"))
            .labelsHidden()
            .textContentType(.password)
            .disabled(model.isBusy)
            .onSubmit { Task { await model.signIn() } }
            .accessibilityIdentifier("passwordField")
            .listRowBackground(cardFill)
        #endif
    }

    @ViewBuilder
    private var addressField: some View {
        #if os(macOS)
        TextField("Hermes address", text: $model.baseURLText, prompt: Text(verbatim: "https://your-host.tailnet.ts.net"))
            .labelsHidden()
            .onChange(of: model.baseURLText) { model.addressChanged() }
        #else
        TextField("https://your-host.tailnet.ts.net", text: $model.baseURLText)
        #endif
    }

    @ViewBuilder
    private var statusRow: some View {
        switch model.phase {
        case .signedOut:
            Text("Not signed in")
                .foregroundStyle(Color(theme.palette.textSecondary))
                .accessibilityIdentifier("statusLabel")
        case .signingIn:
            Text("Signing in")
                .accessibilityIdentifier("statusLabel")
        case .connecting:
            Text("Connecting")
                .accessibilityIdentifier("statusLabel")
        case .connected(let instanceID):
            VStack(alignment: .leading, spacing: 4) {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("statusLabel")
                Text(instanceID)
                    .font(.footnote.monospaced())
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("instanceIDLabel")
            }
        case .failed(let message):
            Text(message)
                .foregroundStyle(Color(theme.palette.destructive))
                .accessibilityIdentifier("errorLabel")
        }
    }
}

struct ConnectionView: View {
    @Bindable var model: ConnectionModel

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        NavigationStack {
            ConnectionForm(model: model)
                .background(Color(theme.palette.sheetBackground).ignoresSafeArea())
                .navigationTitle("Pal")
        }
    }
}
