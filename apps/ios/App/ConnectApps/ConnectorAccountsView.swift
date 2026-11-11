import PalConnect
import PalDesign
import SwiftUI

struct ConnectorAccountsView: View {
    @State private var model: ConnectorAccountsModel
    let style: CustomConnectorStyle
    @Environment(\.dismiss) private var dismiss

    init(model: ConnectorAccountsModel, style: CustomConnectorStyle) {
        _model = State(initialValue: model)
        self.style = style
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.app.name).font(style.titleFont).foregroundStyle(style.primary)
                Spacer()
                Button("Done") { dismiss() }.accessibilityIdentifier("connectorAccountsDone")
            }
            .padding(.horizontal, style.margin)
            .padding(.vertical, 14)
            Rectangle().fill(style.divider).frame(height: 1)
            content
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectorAccounts")
        .task { await model.load() }
        .confirmationDialog(
            model.removal.map { "Remove \($0.name)?" } ?? "",
            isPresented: Binding(get: { model.removal != nil }, set: { if !$0 { model.removal = nil } }),
            titleVisibility: .visible,
            presenting: model.removal
        ) { _ in
            Button("Remove account", role: .destructive) { Task { await model.confirmRemove() } }
            Button("Cancel", role: .cancel) {}
        } message: { account in
            Text("\(model.botName) can no longer use the \(account.name) account of \(model.app.name). Anything that relies on it stops working until you connect it again.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message).font(style.bodyFont).foregroundStyle(style.secondary)
                Button("Try again") { Task { await model.load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            ScrollView {
                VStack(alignment: .leading, spacing: style.spacing) {
                    status
                    accountsSection
                    policySection
                }
                .padding(style.margin)
                .frame(maxWidth: style.maxWidth, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.save {
        case .idle: EmptyView()
        case .saving:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Saving…").font(style.captionFont).foregroundStyle(style.secondary)
            }
        case .saved(let message):
            Text(message).font(style.captionFont).foregroundStyle(style.secondary).accessibilityIdentifier("connectorAccountsSaved")
        case .failed(let message):
            Text(message).font(style.captionFont).foregroundStyle(.red).accessibilityIdentifier("connectorAccountsError")
        }
    }

    private func heading(_ title: LocalizedStringKey) -> some View {
        Text(title).font(style.labelFont).foregroundStyle(style.secondary)
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Accounts")
            if model.accounts.isEmpty {
                Text("No accounts are connected.").font(style.bodyFont).foregroundStyle(style.secondary)
            }
            ForEach(model.active) { account in accountRow(account) }
            ForEach(model.retired) { account in
                accountRow(account, retired: true)
            }
        }
    }

    @ViewBuilder
    private func accountRow(_ account: ConnectorAccount, retired: Bool = false) -> some View {
        if model.editing == account.id {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Account name", text: $model.draft)
                    .textFieldStyle(.plain)
                    .font(style.bodyFont)
                    .padding(.horizontal, 12)
                    .frame(height: style.fieldHeight)
                    .background(style.field, in: RoundedRectangle(cornerRadius: style.fieldRadius))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit { Task { await model.submitRename() } }
                    .accessibilityIdentifier("connectorAccountNameField")
                if let problem = model.draftProblem {
                    Text(problem).font(style.captionFont).foregroundStyle(.red)
                }
                HStack {
                    Button("Save") { Task { await model.submitRename() } }
                        .disabled(model.draftProblem != nil || model.busyAccount != nil)
                        .accessibilityIdentifier("connectorAccountRenameSave")
                    Button("Cancel") { model.cancelRename() }
                }
            }
        } else {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name).font(style.bodyFont).foregroundStyle(style.primary)
                    if let note = rowNote(account, retired: retired) {
                        Text(note).font(style.captionFont).foregroundStyle(account.needsReconnect ? .orange : style.secondary)
                    }
                }
                Spacer()
                if !retired {
                    Button("Rename") { model.beginRename(account) }
                        .disabled(model.busyAccount != nil)
                        .accessibilityIdentifier("connectorAccountRename-\(account.id)")
                }
                Button("Remove", role: .destructive) { model.removal = account }
                    .disabled(model.busyAccount != nil)
                    .accessibilityIdentifier("connectorAccountRemove-\(account.id)")
            }
            .buttonStyle(.borderless)
        }
    }

    private func rowNote(_ account: ConnectorAccount, retired: Bool) -> String? {
        if retired { return String(localized: "No longer in use") }
        if account.needsReconnect { return String(localized: "Needs to be reconnected") }
        return account.alias == nil ? nil : account.label
    }

    private var policySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("What \(model.botName) may do")
            Toggle(isOn: Binding(get: { model.enabled }, set: { value in Task { await model.setEnabled(value) } })) {
                Text("Let \(model.botName) use \(model.app.name)").font(style.bodyFont).foregroundStyle(style.primary)
            }
            .disabled(!model.canEditPolicy || model.save == .saving)
            .accessibilityIdentifier("connectorPolicyEnabled")
            if model.lockedByOrganization {
                Text("Your organization turned this app off.").font(style.captionFont).foregroundStyle(style.secondary)
            } else if model.policy.revision == nil {
                Text("These settings can't be changed here.").font(style.captionFont).foregroundStyle(style.secondary)
            }
            if model.enabled && !model.lockedByOrganization { toolsList }
        }
    }

    @ViewBuilder
    private var toolsList: some View {
        if model.toolsFailed {
            Text("Couldn't load the tools.").font(style.captionFont).foregroundStyle(style.secondary)
        } else if !model.tools.isEmpty {
            heading("Tools")
            ForEach(model.tools) { tool in
                let locked = model.lockedTools.contains(tool.slug)
                Toggle(isOn: Binding(
                    get: { !locked && !model.disabledTools.contains(tool.slug) },
                    set: { value in Task { await model.setTool(tool, allowed: value) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name).font(style.bodyFont).foregroundStyle(style.primary)
                        Text(locked ? String(localized: "Turned off by your organization") : tool.description)
                            .font(style.captionFont).foregroundStyle(style.secondary).lineLimit(2)
                    }
                }
                .disabled(locked || !model.canEditPolicy || model.save == .saving)
                .accessibilityIdentifier("connectorPolicyTool-\(tool.slug)")
            }
        }
    }
}
