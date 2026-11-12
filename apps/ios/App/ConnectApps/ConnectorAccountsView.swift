import PalConnect
import PalDesign
import SwiftUI

struct ConnectorAccountsView: View {
    @State private var model: ConnectorAccountsModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.hermesTheme) private var theme

    init(model: ConnectorAccountsModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        SheetChrome(
            title: model.app.name,
            accessibilityIdentifier: "connectorAccounts",
            leadingAccessibilityIdentifier: "connectorAccountsDone",
            onLeading: { dismiss() },
            content: { content }
        )
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
            page {
                GroupedCard(accessibilityIdentifier: "connectorAccountsLoading") {
                    LoadingRow(title: String(localized: "Accounts"), identifier: "connectorAccountsLoadingRow")
                }
            }
        case .failed(let message):
            page { FailureCard(message: message, identifier: "connectorAccountsFailure") { Task { await model.load() } } }
        case .ready:
            page {
                status
                accountsSection
                policySection
            }
        }
    }

    private func page<Body: View>(@ViewBuilder _ body: () -> Body) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PalMetrics.cardGap) { body() }
                .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private var status: some View {
        switch model.save {
        case .idle: EmptyView()
        case .saving:
            CardFootnote(String(localized: "Saving…"), accessibilityIdentifier: "connectorAccountsSaving")
        case .saved(let message):
            CardFootnote(message, accessibilityIdentifier: "connectorAccountsSaved")
        case .failed(let message):
            problemLine(message, identifier: "connectorAccountsError")
        }
    }

    private func problemLine(_ text: String, identifier: String) -> some View {
        Text(text)
            .hermesText(.rowSubtitle)
            .foregroundStyle(Color(theme.palette.destructive))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PalMetrics.screenMargin + PalMetrics.rowInset - 3)
            .accessibilityIdentifier(identifier)
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
            SectionCaption(String(localized: "Accounts"), accessibilityIdentifier: "connectorAccountsCaption")
            if model.accounts.isEmpty {
                CardFootnote(String(localized: "No accounts are connected."), accessibilityIdentifier: "connectorAccountsEmpty")
            }
            ForEach(model.active) { account in accountCard(account) }
            ForEach(model.retired) { account in accountCard(account, retired: true) }
        }
    }

    @ViewBuilder
    private func accountCard(_ account: ConnectorAccount, retired: Bool = false) -> some View {
        GroupedCard(accessibilityIdentifier: "connectorAccount-\(account.id)") {
            if model.editing == account.id {
                renameRows
            } else {
                SettingsRow(
                    title: account.name, subtitle: rowNote(account, retired: retired),
                    accessibilityIdentifier: "connectorAccountName-\(account.id)"
                )
                if !retired {
                    SettingsRow(
                        title: String(localized: "Rename"), accessibilityIdentifier: "connectorAccountRename-\(account.id)",
                        action: { model.beginRename(account) }
                    )
                    .disabled(model.busyAccount != nil)
                }
                SettingsRow.destructive(String(localized: "Remove"), accessibilityIdentifier: "connectorAccountRemove-\(account.id)") {
                    model.removal = account
                }
                .disabled(model.busyAccount != nil)
            }
        }
    }

    @ViewBuilder
    private var renameRows: some View {
        TextField(String(localized: "Account name"), text: $model.draft)
            .textFieldStyle(.plain)
            .hermesText(.rowTitle)
            .autocorrectionDisabled()
            .neverAutocapitalized()
            .onSubmit { Task { await model.submitRename() } }
            .padding(.horizontal, PalMetrics.rowInset)
            .frame(minHeight: PalMetrics.rowMinimumHeight)
            .accessibilityIdentifier("connectorAccountNameField")
        if let problem = model.draftProblem {
            problemLine(problem, identifier: "connectorAccountNameProblem")
        }
        SettingsRow(
            title: String(localized: "Save"), accessibilityIdentifier: "connectorAccountRenameSave",
            action: { Task { await model.submitRename() } }
        )
        .disabled(model.draftProblem != nil || model.busyAccount != nil)
        SettingsRow(title: String(localized: "Cancel"), accessibilityIdentifier: "connectorAccountRenameCancel") { model.cancelRename() }
    }

    private func rowNote(_ account: ConnectorAccount, retired: Bool) -> String? {
        if retired { return String(localized: "No longer in use") }
        if account.needsReconnect { return String(localized: "Needs to be reconnected") }
        return account.alias == nil ? nil : account.label
    }

    private var policySection: some View {
        VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
            SectionCaption(String(localized: "What \(model.botName) may do"), accessibilityIdentifier: "connectorPolicyCaption")
            GroupedCard(accessibilityIdentifier: "connectorPolicy") {
                SettingsRow.toggle(
                    String(localized: "Let \(model.botName) use \(model.app.name)"),
                    isOn: Binding(get: { model.enabled }, set: { value in Task { await model.setEnabled(value) } }),
                    accessibilityIdentifier: "connectorPolicyEnabled"
                )
                .disabled(!model.canEditPolicy || model.save == .saving)
            }
            if model.lockedByOrganization {
                CardFootnote(String(localized: "Your organization turned this app off."), accessibilityIdentifier: "connectorPolicyLocked")
            } else if model.policy.revision == nil {
                CardFootnote(String(localized: "These settings can't be changed here."), accessibilityIdentifier: "connectorPolicyReadOnly")
            }
            if model.enabled && !model.lockedByOrganization { toolsList }
        }
    }

    @ViewBuilder
    private var toolsList: some View {
        if model.toolsFailed {
            CardFootnote(String(localized: "Couldn't load the tools."), accessibilityIdentifier: "connectorToolsFailed")
        } else if !model.tools.isEmpty {
            SectionCaption(String(localized: "Tools"), accessibilityIdentifier: "connectorToolsCaption")
                .padding(.top, PalMetrics.cardGap - PalMetrics.captionToCardGap)
            GroupedCard(accessibilityIdentifier: "connectorTools") {
                ForEach(model.tools) { tool in toolRow(tool) }
            }
        }
    }

    private func toolRow(_ tool: HostedConnectorTool) -> some View {
        let locked = model.lockedTools.contains(tool.slug)
        return SettingsRow.toggle(
            tool.name,
            subtitle: locked ? String(localized: "Turned off by your organization") : (tool.description.isEmpty ? nil : tool.description),
            isOn: Binding(
                get: { !locked && !model.disabledTools.contains(tool.slug) },
                set: { value in Task { await model.setTool(tool, allowed: value) } }
            ),
            accessibilityIdentifier: "connectorPolicyTool-\(tool.slug)"
        )
        .disabled(locked || !model.canEditPolicy || model.save == .saving)
    }
}
