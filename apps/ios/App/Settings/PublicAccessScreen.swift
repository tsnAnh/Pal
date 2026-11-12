import PalBotProfile
import PalDesign
import SwiftUI

enum PublicAccessCopy {
    static let title = "Public access"
    static let rowSubtitle = "Addresses outside services use to reach your bot"
    static let blindSpots = "The tunnel or proxy that makes your computer reachable lives outside Pal, so the app can't see inside it. It can only tell whether the public address answers, resolves and has a valid certificate."
    static let secretNote = "Shown once, copy it into GitHub now."
}

extension WebhookRoutesModel {
    @MainActor
    static func make(hub: SettingsHub) -> WebhookRoutesModel {
        let connection = hub.connection
        let gateway = BotsGateway { method, params in try await connection.rpc(method, params) }
        return WebhookRoutesModel(client: WebhookRoutesClient(gateway: gateway))
    }
}

struct PublicAccessScreen: View {
    let hub: SettingsHub
    let back: () -> Void

    @State private var model: WebhookRoutesModel
    @State private var adding = false

    init(hub: SettingsHub, back: @escaping () -> Void) {
        self.hub = hub
        self.back = back
        _model = State(initialValue: WebhookRoutesModel.make(hub: hub))
    }

    var body: some View {
        SettingsPage(
            title: PublicAccessCopy.title, identifier: "publicAccessScreen", back: back,
            trailing: {
                if model.canManage {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel(Text("Add a public address"))
                        .accessibilityIdentifier("publicAccessAddButton")
                        .tint(.primary)
                }
            },
            content: { PublicAccessContent(model: model, adding: $adding) }
        )
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
    }
}

struct PublicAccessContent: View {
    let model: WebhookRoutesModel
    @Binding var adding: Bool

    @State private var removing: WebhookRoute?
    @State private var copiedRoute: String?

    var body: some View {
        VStack(alignment: .leading, spacing: PalMetrics.cardGap) {
            VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
                GroupedCard(accessibilityIdentifier: "publicAccessCard") {
                    SettingsRow.value(
                        "Public address", value: addressText, subtitle: model.list?.missingSettingHint,
                        accessibilityIdentifier: "publicAccessAddress")
                    SettingsRow(
                        title: "Refresh", trailing: .none, accessibilityIdentifier: "publicAccessRefresh",
                        action: { Task { await model.refresh() } })
                }
                if let footnote = model.footnote {
                    CardFootnote(footnote, accessibilityIdentifier: "publicAccessFootnote")
                }
            }
            if model.canManage { routesSection }
            VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
                SectionCaption("What the app can't see", accessibilityIdentifier: "publicAccessBlindSpotsCaption")
                CardFootnote(PublicAccessCopy.blindSpots, accessibilityIdentifier: "publicAccessBlindSpots")
            }
        }
        .sheet(isPresented: $adding, onDismiss: { model.clearIssuedSecret(); model.resetAdd() }) {
            AddPublicRouteSheet(model: model) { adding = false }
                .macSheetFrame()
        }
        .alert(
            "Public access", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.notice ?? "")
        }
        .confirmationDialog(
            "Remove this public address?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible, presenting: removing
        ) { route in
            Button("Remove", role: .destructive) { Task { await model.remove(route.name) } }
                .accessibilityIdentifier("publicAccessRemoveConfirm")
            Button("Cancel", role: .cancel) {}
        } message: { route in
            Text("Services using \(route.name) will stop reaching your bot.")
        }
    }

    private var addressText: String {
        switch model.phase {
        case .loading: "Checking…"
        case .ready(let list): list.publicAddressText
        case .unsupported, .notOwner, .unavailable: "Unknown"
        }
    }

    @ViewBuilder
    private var routesSection: some View {
        VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
            SectionCaption("Addresses", accessibilityIdentifier: "publicAccessRoutesCaption")
            if model.routes.isEmpty {
                GroupedCard(accessibilityIdentifier: "publicAccessEmptyCard") {
                    PlaceholderRow("No public addresses yet", accessibilityIdentifier: "publicAccessEmptyRow")
                }
            } else {
                ForEach(model.routes) { route in routeCard(route) }
            }
        }
    }

    private func routeCard(_ route: WebhookRoute) -> some View {
        GroupedCard(accessibilityIdentifier: "publicRoute-\(route.name)") {
            SettingsRow.value(
                route.name, value: route.isEnabled ? "On" : "Off", subtitle: routeSubtitle(route),
                accessibilityIdentifier: "publicRouteSummary-\(route.name)")
            HStack(spacing: 8) {
                PillButton(
                    copiedRoute == route.name ? "Copied" : "Copy address", kind: route.publicURL == nil ? .dimmed : .neutral,
                    accessibilityIdentifier: "publicRouteCopy-\(route.name)"
                ) { copy(route) }
                    .disabled(route.publicURL == nil)
                PillButton(
                    model.probes[route.name] == .running ? "Checking…" : "Check", kind: .accent,
                    isBusy: model.probes[route.name] == .running, accessibilityIdentifier: "publicRouteProbe-\(route.name)"
                ) { Task { await model.probe(route.name) } }
                PillButton("Remove", accessibilityIdentifier: "publicRouteRemove-\(route.name)") { removing = route }
            }
            .padding(.horizontal, PalMetrics.rowInset)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            probeResult(route)
        }
    }

    private func routeSubtitle(_ route: WebhookRoute) -> String {
        let address = route.publicURL?.absoluteString ?? "No public address"
        let events = route.events.isEmpty ? "All events" : route.events.joined(separator: ", ")
        return "\(address)\n\(events)"
    }

    @ViewBuilder
    private func probeResult(_ route: WebhookRoute) -> some View {
        switch model.probes[route.name] {
        case .finished(let probe)?: PublicProbeResultView(probe: probe, identifier: route.name)
        case .failed?:
            Text("We couldn't run the check. Please try again.")
                .hermesText(.rowSubtitle)
                .foregroundStyle(PalTokens.textSecondary)
                .padding(.horizontal, PalMetrics.rowInset)
                .padding(.vertical, 8)
                .accessibilityIdentifier("publicRouteProbeFailed-\(route.name)")
        case .running?, nil: EmptyView()
        }
    }

    private func copy(_ route: WebhookRoute) {
        guard let url = route.publicURL else { return }
        Pasteboard.string = url.absoluteString
        copiedRoute = route.name
    }
}

private struct PublicProbeResultView: View {
    let probe: WebhookProbe
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(probe.diagnosis.headline)
                    .hermesText(.rowTitle)
                    .foregroundStyle(PalTokens.textPrimary)
            }
            if !probe.diagnosis.message.isEmpty {
                Text(probe.diagnosis.message)
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(PalTokens.textSecondary)
            }
            Text("On your computer: \(probe.local.summary)")
                .hermesText(.rowSubtitle)
                .foregroundStyle(PalTokens.textSecondary)
            Text("Public address: \(probe.publicHop.summary)")
                .hermesText(.rowSubtitle)
                .foregroundStyle(PalTokens.textSecondary)
            if let resolves = probe.resolves {
                Text(resolves ? "The address resolves." : "The address doesn't resolve.")
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(PalTokens.textSecondary)
            }
            if let expires = probe.certificateExpiresAt {
                Text("Certificate valid until \(expires)")
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(PalTokens.textSecondary)
            }
        }
        .padding(.horizontal, PalMetrics.rowInset)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("publicRouteProbeResult-\(identifier)")
    }

    private var symbol: String {
        switch probe.diagnosis.severity {
        case .good: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        case .neutral: "info.circle.fill"
        }
    }

    private var tint: Color {
        switch probe.diagnosis.severity {
        case .good: .green
        case .warning: .orange
        case .failure: .red
        case .neutral: PalTokens.textSecondary
        }
    }
}

private struct AddPublicRouteSheet: View {
    let model: WebhookRoutesModel
    let close: () -> Void

    @State private var draft = WebhookRouteDraft()
    @State private var hasOwnSecret = false
    @State private var copied = false
    @Environment(\.hermesTheme) private var theme

    var body: some View {
        SheetChrome(
            title: "Add a public address", accessibilityIdentifier: "publicAccessAddSheet", onLeading: close,
            trailing: {
                if model.issuedSecret == nil, !hasOwnSecret {
                    PillButton(
                        "Create", kind: draft.isComplete ? .accent : .dimmed, isBusy: model.addState == .saving,
                        accessibilityIdentifier: "publicAccessCreateButton"
                    ) {
                        Task { _ = await model.add(draft, typedSecret: nil) }
                    }
                    .disabled(!draft.isComplete)
                }
            },
            content: {
                ScrollView {
                    VStack(alignment: .leading, spacing: PalMetrics.cardGap) {
                        if let secret = model.issuedSecret {
                            issued(secret)
                        } else {
                            form
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
        )
    }

    @ViewBuilder
    private var form: some View {
        GroupedCard(accessibilityIdentifier: "publicAccessAddFields") {
            field("Name", text: $draft.name, identifier: "publicAccessNameField")
            field("Events (optional)", text: $draft.eventsText, identifier: "publicAccessEventsField")
        }
        CardFootnote(
            "The name becomes part of the address. List events separated by commas, or leave it empty to accept every event.",
            accessibilityIdentifier: "publicAccessAddFootnote")
        GroupedCard(accessibilityIdentifier: "publicAccessSecretCard") {
            SettingsRow.toggle(
                "I already have a signing secret", isOn: $hasOwnSecret, accessibilityIdentifier: "publicAccessOwnSecretToggle")
        }
        if hasOwnSecret {
            SecretEntryView(
                connectorName: "Signing secret",
                accountLabel: draft.trimmedName,
                purpose: String(localized: "Paste the signing secret you set in GitHub. It is saved on your computer and can't be read back."),
                fieldLabel: "Signing secret",
                state: entryState,
                identifiers: SecretEntryIdentifiers(
                    field: "publicAccessSecretField", submit: "publicAccessSecretSave",
                    cancel: "publicAccessSecretCancel", status: "publicAccessSecretStatus"
                ),
                onSubmit: { value in
                    guard draft.isComplete else { return }
                    Task { if await model.add(draft, typedSecret: value) { close() } }
                },
                onCancel: close
            )
            .padding(.horizontal, PalMetrics.screenMargin)
        } else {
            CardFootnote(
                "Pal will make a signing secret for you and show it once.", accessibilityIdentifier: "publicAccessGenerateNote")
        }
        if case .failed(let text) = model.addState, !hasOwnSecret {
            CardFootnote(text, accessibilityIdentifier: "publicAccessAddFailure")
        }
    }

    private var entryState: SecretEntryState {
        switch model.addState {
        case .idle: .idle
        case .saving: .submitting
        case .failed(let text): .failure(text)
        }
    }

    private func field(_ title: String, text: Binding<String>, identifier: String) -> some View {
        TextField(title, text: text)
            .neverAutocapitalized()
            .autocorrectionDisabled()
            .hermesText(.rowTitle)
            .foregroundStyle(Color(theme.palette.textPrimary))
            .padding(.horizontal, PalMetrics.rowInset)
            .frame(minHeight: PalMetrics.rowMinimumHeight)
            .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private func issued(_ secret: String) -> some View {
        GroupedCard(accessibilityIdentifier: "publicAccessSecretIssued") {
            Text(secret)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(PalTokens.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, PalMetrics.rowInset)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("publicAccessIssuedSecret")
            HStack {
                PillButton(copied ? "Copied" : "Copy", kind: .accent, accessibilityIdentifier: "publicAccessCopySecret") {
                    Pasteboard.string = secret
                    copied = true
                }
                PillButton("Done", accessibilityIdentifier: "publicAccessSecretDone", action: close)
            }
            .padding(.horizontal, PalMetrics.rowInset)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        CardFootnote(PublicAccessCopy.secretNote, accessibilityIdentifier: "publicAccessSecretNote")
    }
}
