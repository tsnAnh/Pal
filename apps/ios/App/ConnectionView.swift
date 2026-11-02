import SwiftUI

struct ConnectionView: View {
    @Bindable var model: ConnectionModel
    let onDone: (() -> Void)?

    var body: some View {
        NavigationStack {
            Form {
                if !model.isConnected {
                    Section("Hermes address") {
                        TextField("https://your-host.tailnet.ts.net", text: $model.baseURLText)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("baseURLField")
                            .disabled(model.isBusy)
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
                    }
                }
                Section("Status") {
                    statusRow
                }
                if case .connected = model.phase {
                    Section {
                        Button("Sign out", role: .destructive) {
                            Task { await model.signOut() }
                        }
                        .accessibilityIdentifier("signOutButton")
                    }
                }
            }
            .navigationTitle("Hermes Bots")
            .toolbar {
                if let onDone {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                            .accessibilityIdentifier("settingsDone")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch model.phase {
        case .signedOut:
            Text("Not signed in")
                .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("instanceIDLabel")
            }
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .accessibilityIdentifier("errorLabel")
        }
    }
}
