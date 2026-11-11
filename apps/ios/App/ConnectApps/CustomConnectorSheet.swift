import HermesConnect
import HermesDesign
import SwiftUI

struct CustomConnectorSheet: View {
    @Bindable var model: CustomConnectorModel
    let close: () -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        SheetChrome(
            title: model.title,
            accessibilityIdentifier: "customConnector",
            onLeading: close,
            trailing: { trailingButton },
            content: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if model.screen == .form { formContent } else { resultContent }
                    }
                    .padding(.horizontal, HermesMetrics.screenMargin)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        )
        .task { await model.begin() }
        .onChange(of: model.removed) { _, removed in
            if removed { close() }
        }
        .confirmationDialog(
            "Remove \(model.title)?",
            isPresented: $model.confirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { Task { await model.remove() } }
                .accessibilityIdentifier("customConnectorRemoveConfirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your bots lose access to this connector.")
        }
    }

    @ViewBuilder
    private var trailingButton: some View {
        if model.screen == .form {
            Button("Save") { Task { await model.save() } }
                .disabled(!model.canSave)
                .accessibilityIdentifier("customConnectorSaveButton")
                #if os(macOS)
                .buttonStyle(.glass)
                #endif
        } else {
            Button("Edit") { model.edit() }
                .disabled(model.isBusy)
                .accessibilityIdentifier("customConnectorEditButton")
                #if os(macOS)
                .buttonStyle(.glass)
                #endif
        }
    }

    @ViewBuilder
    private var formContent: some View {
        TextField("Name", text: $model.name)
            .neverAutocapitalized()
            .autocorrectionDisabled()
            .disabled(model.isEditing || model.isBusy)
            .fieldChrome(theme)
            .accessibilityIdentifier("customConnectorNameField")
        TextField("Server address", text: $model.url)
            .neverAutocapitalized()
            .autocorrectionDisabled()
            #if os(iOS)
            .keyboardType(.URL)
            #endif
            .disabled(model.isBusy)
            .fieldChrome(theme)
            .accessibilityIdentifier("customConnectorURLField")
        labeled("Connection") {
            Picker("Connection", selection: $model.transport) {
                Text("Streamable HTTP").tag(CustomConnectorTransport.http)
                Text("SSE").tag(CustomConnectorTransport.sse)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.isBusy)
            .accessibilityIdentifier("customConnectorTransportPicker")
        }
        labeled("Sign-in") {
            Picker("Sign-in", selection: $model.auth) {
                Text("None").tag(CustomConnectorAuth.none)
                Text("Bearer token").tag(CustomConnectorAuth.bearer)
                Text("OAuth").tag(CustomConnectorAuth.oauth)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.isBusy)
            .accessibilityIdentifier("customConnectorAuthPicker")
        }
        if model.auth == .bearer { tokenField }
        if model.auth == .oauth {
            caption("Your browser opens so you can sign in to the server.")
        }
        status
        if model.isEditing {
            PillButton("Cancel", size: .large, accessibilityIdentifier: "customConnectorCancelEditButton") {
                Task { await model.cancelEditing() }
            }
        }
    }

    @ViewBuilder
    private var tokenField: some View {
        let keepsToken = model.existing?.auth == .bearer
        SecureField(keepsToken ? "Token set" : "Token", text: $model.token)
            .textContentType(.password)
            .neverAutocapitalized()
            .autocorrectionDisabled()
            .disabled(model.isBusy)
            .fieldChrome(theme)
            .accessibilityIdentifier("customConnectorTokenField")
        if keepsToken { caption("Leave this empty to keep the current token.") }
    }

    @ViewBuilder
    private var status: some View {
        if let progress = model.progressText {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progress).foregroundStyle(Color(theme.palette.textSecondary))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("customConnectorProgress")
        }
        if let failure = model.failure {
            Text(failure.message)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("customConnectorError")
        }
    }

    @ViewBuilder
    private var resultContent: some View {
        status
        if case .connected(let tools) = model.phase {
            sectionTitle(tools.count == 1 ? "1 tool" : "\(tools.count) tools")
            ForEach(tools) { tool in
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.name).foregroundStyle(Color(theme.palette.textPrimary))
                    if !tool.description.isEmpty {
                        Text(tool.description)
                            .font(.footnote)
                            .foregroundStyle(Color(theme.palette.textSecondary))
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("customConnectorTool-\(tool.name)")
            }
        }
        if !model.switches.isEmpty {
            sectionTitle("Use with")
            ForEach(model.switches) { bot in
                Toggle(
                    bot.displayName,
                    isOn: Binding(get: { bot.isOn }, set: { on in Task { await model.setBot(bot.id, on: on) } })
                )
                .disabled(bot.isBusy || model.isBusy)
                .accessibilityIdentifier("customConnectorBot-\(bot.id)")
            }
        }
        if let notice = model.switchNotice {
            caption(notice).accessibilityIdentifier("customConnectorNotice")
        }
        if let failure = model.removeFailure {
            Text(failure.message).foregroundStyle(.red).accessibilityIdentifier("customConnectorRemoveError")
        }
        Button("Remove connector", role: .destructive) { model.confirmingRemove = true }
            .disabled(model.isBusy)
            .padding(.top, 8)
            .accessibilityIdentifier("customConnectorRemoveButton")
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            caption(title)
            content()
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(Color(theme.palette.textPrimary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Color(theme.palette.textSecondary))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    func fieldChrome(_ theme: HermesTheme) -> some View {
        padding(.horizontal, 16)
            .frame(height: 48)
            .background(Color(theme.palette.groupedCard), in: RoundedRectangle(cornerRadius: HermesMetrics.cardRadius, style: .continuous))
    }
}
