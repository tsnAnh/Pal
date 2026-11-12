import PalBotProfile
import PalDesign
import SwiftUI

enum HostKitCopy {
    static let title = "Kit"
    static let rowSubtitle = "Version, update, projects and reloads on this host"
    static let footnote = "The kit on the computer you're connected to. Operations run one at a time."
}

struct HostKitScreen: View {
    let hub: SettingsHub
    let back: () -> Void

    @State private var model: KitModel
    @State private var repo = ""
    @State private var confirmingGatewayReload = false

    init(hub: SettingsHub, back: @escaping () -> Void) {
        self.hub = hub
        self.back = back
        let connection = hub.connection
        let gateway = BotsGateway { method, params in try await connection.rpc(method, params) }
        _model = State(initialValue: KitModel(client: KitClient(gateway: gateway)))
    }

    var body: some View {
        SettingsPage(title: HostKitCopy.title, identifier: "hostKitScreen", back: back) {
            GroupedCard(accessibilityIdentifier: "hostKitStatusCard") {
                SettingsRow.value("Version", value: versionText, accessibilityIdentifier: "hostKitVersion")
                if let status = model.report?.status {
                    SettingsRow.value("Status", value: status, subtitle: model.report?.message, accessibilityIdentifier: "hostKitStatus")
                }
            }
            if model.phase != .failed(.gatewayUnsupported) {
                actionsCard
                projectCard
                reloadCard
            }
            outcomeNote
            CardFootnote(footnoteText, accessibilityIdentifier: "hostKitFootnote")
        }
        .task { await model.refreshStatus() }
        .refreshable { await model.refreshStatus() }
        .confirmationDialog("Reload the gateway?", isPresented: $confirmingGatewayReload, titleVisibility: .visible) {
            Button("Reload gateway", role: .destructive) { Task { await model.reload(.gateway) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Chats on this host reconnect once it is back.")
        }
    }

    private var actionsCard: some View {
        GroupedCard(accessibilityIdentifier: "hostKitActionsCard") {
            SettingsRow(
                title: title(.refresh, idle: "Refresh kit", busy: "Refreshing…"), trailing: .none,
                accessibilityIdentifier: "hostKitRefreshRow", action: { Task { await model.refresh() } }
            )
            .disabled(!model.canAct)
            SettingsRow(
                title: title(.update, idle: "Update to latest", busy: "Updating…"), trailing: .none,
                accessibilityIdentifier: "hostKitUpdateRow", action: { Task { await model.update() } }
            )
            .disabled(!model.canAct)
        }
    }

    private var projectCard: some View {
        GroupedCard(accessibilityIdentifier: "hostKitProjectCard") {
            TextField("Project", text: $repo, prompt: Text("owner/repo"))
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(addProject)
                .padding(.horizontal, PalMetrics.rowInset)
                .frame(minHeight: PalMetrics.rowMinimumHeight)
                .accessibilityLabel(Text("Project"))
                .accessibilityIdentifier("hostKitProjectField")
            SettingsRow(
                title: title(.addProject, idle: "Add project", busy: "Adding…"), value: projectValue, trailing: .none,
                accessibilityIdentifier: "hostKitAddProjectRow", action: addProject
            )
            .disabled(!model.canAct || !KitRepo.isValid(repo.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    private var reloadCard: some View {
        GroupedCard(accessibilityIdentifier: "hostKitReloadCard") {
            SettingsRow(
                title: title(.reload, idle: "Reload routes", busy: "Reloading…"), trailing: .none,
                accessibilityIdentifier: "hostKitReloadRoutesRow", action: { Task { await model.reload(.routes) } }
            )
            .disabled(!model.canAct)
            SettingsRow(
                title: "Reload gateway", trailing: .none,
                accessibilityIdentifier: "hostKitReloadGatewayRow", action: { confirmingGatewayReload = true }
            )
            .disabled(!model.canAct)
        }
    }

    @ViewBuilder
    private var outcomeNote: some View {
        if let text = outcomeText {
            CardFootnote(text, accessibilityIdentifier: "hostKitOutcome")
        }
    }

    private func title(_ operation: KitOperation, idle: String, busy: String) -> String {
        model.running == operation ? busy : idle
    }

    private func addProject() {
        Task { await model.addProject(repo) }
    }

    private var versionText: String {
        switch model.phase {
        case .loading: " "
        case .ready(let report): report.version ?? "Unknown"
        case .failed(.kitUnavailable): "Not installed"
        case .failed(.gatewayUnsupported): "Not supported yet"
        case .failed: "Unavailable"
        }
    }

    private var projectValue: String? {
        switch model.outcome {
        case .succeeded(.addProject, _)?: "Saved"
        case .failed(.addProject, _)?: "Failed"
        default: nil
        }
    }

    private var footnoteText: String {
        if case .failed(let failure) = model.phase { return failure.message }
        return HostKitCopy.footnote
    }

    private var outcomeText: String? {
        switch model.outcome {
        case nil: return nil
        case .succeeded(_, let report)?: return report.message ?? "Done."
        case .failed(_, let failure)?:
            guard let tail = failure.tail else { return failure.message }
            return "\(failure.message) \(tail)"
        }
    }
}
