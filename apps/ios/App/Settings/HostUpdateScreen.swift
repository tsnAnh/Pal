import PalBotProfile
import PalDesign
import SwiftUI

struct HostUpdateScreen: View {
    let hub: SettingsHub
    let back: () -> Void

    @State private var model: HostUpdateModel

    init(hub: SettingsHub, back: @escaping () -> Void) {
        self.hub = hub
        self.back = back
        let connection = hub.connection
        let gateway = BotsGateway { method, params in try await connection.rpc(method, params) }
        _model = State(initialValue: HostUpdateModel(client: HostUpdateClient(gateway: gateway), surfaces: connection.surfaces))
    }

    var body: some View {
        SettingsPage(title: "Update", identifier: "hostUpdateScreen", back: back) {
            GroupedCard(accessibilityIdentifier: "hostUpdateVersionCard") {
                SettingsRow.value(
                    "Version", value: model.check?.version ?? " ", accessibilityIdentifier: "hostUpdateVersion")
                SettingsRow.value("Status", value: statusText, accessibilityIdentifier: "hostUpdateStatus")
            }
            GroupedCard(accessibilityIdentifier: "hostUpdateActionCard") {
                SettingsRow(
                    title: model.checking ? "Checking…" : "Check for updates", trailing: .none,
                    accessibilityIdentifier: "hostUpdateCheckRow",
                    action: { Task { await model.refreshCheck() } }
                )
                .disabled(model.checking || model.isUpdating)
                if model.check?.canUpdate == true {
                    SettingsRow(
                        title: "Update", subtitle: updateSubtitle, trailing: .none,
                        accessibilityIdentifier: "hostUpdateApplyRow",
                        action: { Task { await model.requestUpdate() } }
                    )
                    .disabled(model.isUpdating)
                }
                if let link = model.check?.releaseNotesURL {
                    SettingsRow.external("What's new", accessibilityIdentifier: "hostUpdateNotesRow") { ExternalLink.open(link) }
                }
            }
            CardFootnote(footnote, accessibilityIdentifier: "hostUpdateFootnote")
        }
        .task { await model.load() }
        .refreshable { await model.refreshCheck() }
        .confirmationDialog(
            "A chat is running", isPresented: $model.confirmingTurns, titleVisibility: .visible
        ) {
            Button("Update anyway", role: .destructive) { Task { await model.start(confirmTurns: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Updating restarts Pal and interrupts the chat.")
        }
        .sheet(isPresented: $model.showingProgress, onDismiss: { model.dismissProgress() }) {
            HostUpdateProgressSheet(model: model) { model.showingProgress = false }
                .macSheetFrame()
                .interactiveDismissDisabled(model.isUpdating)
        }
    }

    private var statusText: String {
        guard let check = model.check else { return model.checkFailed ? "Unavailable" : " " }
        return switch check.status {
        case .upToDate: "Up to date"
        case .updateAvailable: "Update available"
        case .unknown: check.offline ? "Offline" : "Unknown"
        }
    }

    private var updateSubtitle: String? {
        guard let behind = model.check?.commitsBehind, behind > 0 else { return nil }
        return behind == 1 ? "1 change waiting" : "\(behind) changes waiting"
    }

    private var footnote: String {
        if let notice = model.notice { return notice }
        if model.checkFailed { return "Couldn't reach Pal. Pull to refresh." }
        if model.check?.offline == true { return "The computer Pal runs on can't reach the internet." }
        if model.check?.hardBlockers.contains(.dirtyInstall) == true {
            return "This copy of Pal has local changes, so it can't update itself."
        }
        return "Updating restarts Pal on the computer you're connected to."
    }
}

private struct HostUpdateProgressSheet: View {
    let model: HostUpdateModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Updating Pal")
                .hermesText(.sheetTitle)
                .foregroundStyle(PalTokens.textPrimary)
            content
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(PalTokens.elevated)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hostUpdateSheet")
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch model.progress {
        case .running(let phase, let tail)?:
            working(phase: phase, tail: tail, message: nil)
        case .gatewayRestarting(let phase, let tail)?:
            working(phase: phase, tail: tail, message: "Updating… Pal is restarting")
        case .succeeded(let version)?:
            message("Pal is now on version \(version).")
            closeButton("Done", kind: .accent)
        case .failed(let failure, let tail)?:
            message(HostUpdateModel.failureText(failure))
            tailView(tail)
            closeButton("Close")
        case .didNotComeBack(let phase)?:
            message("Pal didn't come back after restarting. Check the computer Pal runs on, then try again.")
            if let phase { message("Last step: \(HostUpdateModel.phaseTitle(phase)).") }
            closeButton("Close")
        case nil:
            ProgressView().accessibilityIdentifier("hostUpdateStarting")
        }
    }

    private func working(phase: HostUpdatePhase?, tail: [String], message text: String?) -> some View {
        VStack(spacing: 12) {
            ProgressView().accessibilityIdentifier("hostUpdateWorking")
            message(text ?? phase.map(HostUpdateModel.phaseTitle) ?? "Getting ready")
            tailView(tail)
        }
    }

    @ViewBuilder
    private func tailView(_ tail: [String]) -> some View {
        if !tail.isEmpty {
            ScrollView {
                Text(tail.suffix(12).joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .foregroundStyle(PalTokens.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 160)
            .accessibilityIdentifier("hostUpdateTail")
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .hermesText(.rowSubtitle)
            .foregroundStyle(PalTokens.textSecondary)
            .multilineTextAlignment(.center)
    }

    private func closeButton(_ title: String, kind: PillKind = .dimmed) -> some View {
        PillButton(title, kind: kind, size: .large, accessibilityIdentifier: "hostUpdateClose", action: close)
    }
}
