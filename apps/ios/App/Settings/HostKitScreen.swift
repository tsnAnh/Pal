import PalBotProfile
import PalDesign
import SwiftUI

enum HostKitCopy {
    static let title = "Kit"
    static let rowSubtitle = "Version, update, key and reloads on this host"
    static let footnote = "The kit on the computer you're connected to. Operations run one at a time."
}

struct HostKitScreen: View {
    let hub: SettingsHub
    let back: () -> Void

    @State private var model: KitModel
    @State private var confirmingGatewayReload = false
    @State private var confirmingRotate = false

    init(hub: SettingsHub, back: @escaping () -> Void) {
        self.hub = hub
        self.back = back
        let connection = hub.connection
        let gateway = BotsGateway { method, params in try await connection.rpc(method, params) }
        _model = State(initialValue: KitModel(client: KitClient(gateway: gateway), surfaces: connection.surfaces))
    }

    var body: some View {
        SettingsPage(title: HostKitCopy.title, identifier: "hostKitScreen", back: back) {
            GroupedCard(accessibilityIdentifier: "hostKitStatusCard") {
                SettingsRow.value("Version", value: versionText, accessibilityIdentifier: "hostKitVersion")
                if let status = model.report?.status {
                    SettingsRow.value("Status", value: status, subtitle: model.report?.message, accessibilityIdentifier: "hostKitStatus")
                }
                if let credential = model.credentialText {
                    SettingsRow.value("Key", value: credential, accessibilityIdentifier: "hostKitCredential")
                }
            }
            if model.phase != .failed(.gatewayUnsupported) {
                actionsCard
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
        .confirmationDialog("Replace the app's key to the kit?", isPresented: $confirmingRotate, titleVisibility: .visible) {
            Button("Replace key", role: .destructive) { Task { await model.rotate() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app uses the new key from its next request.")
        }
    }

    private var actionsCard: some View {
        GroupedCard(accessibilityIdentifier: "hostKitActionsCard") {
            SettingsRow(
                title: title(.update, idle: "Update kit", busy: "Updating…"), trailing: .none,
                accessibilityIdentifier: "hostKitUpdateRow", action: { Task { await model.update() } }
            )
            .disabled(!model.canAct)
            SettingsRow(
                title: title(.rotate, idle: "Rotate key", busy: "Rotating…"), trailing: .none,
                accessibilityIdentifier: "hostKitRotateRow", action: { confirmingRotate = true }
            )
            .disabled(!model.canRotate)
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

    private var versionText: String {
        switch model.phase {
        case .loading: " "
        case .ready(let report): report.version ?? "Unknown"
        case .failed(.kitUnavailable): "Not installed"
        case .failed(.busy): "Updating…"
        case .failed(.gatewayUnsupported): "Not supported yet"
        case .failed: "Unavailable"
        }
    }

    private var footnoteText: String {
        if case .failed(let failure) = model.phase { return failure.message }
        return HostKitCopy.footnote
    }

    private var outcomeText: String? {
        switch model.outcome {
        case nil: return nil
        case .succeeded(_, let report)?: return [report.message ?? "Done.", report.nextAction].compactMap { $0 }.joined(separator: " ")
        case .failed(_, let failure)?:
            return [failure.message, failure.tail].compactMap { $0 }.joined(separator: " ")
        }
    }
}
