import PalDesign
import PalProtocol
import PalSettings
import Observation
import SwiftUI

@MainActor
@Observable
final class VaultModel {
    private(set) var state: Loadable<[VaultEntry]> = .loading
    private(set) var isBusy = false
    var actionFailure: String?

    private let surfaces: SurfaceCache
    private let surfaceKey: SurfaceKey

    init(surfaces: SurfaceCache, profile: String? = nil) {
        self.surfaces = surfaces
        surfaceKey = profile.map { SurfaceKey.screen("vault", bot: $0) } ?? SurfaceKey.screen("vault")
        if let held = surfaces.remembered([VaultEntry].self, surfaceKey) { state = .loaded(held) }
    }

    func load(api: SettingsAPI, surfacingFailure: Bool = false) async {
        do {
            let entries = try await api.vaultItems().map(VaultEntry.init)
            state = .loaded(entries)
            surfaces.remember(entries, surfaceKey)
        } catch is CancellationError {
            return
        } catch {
            if state.value == nil {
                state = .failed(SettingsFailure(error).message)
            } else if surfacingFailure {
                actionFailure = SettingsFailure(error).message
            }
        }
    }

    func add(_ draft: VaultLoginDraft, api: SettingsAPI) async -> Bool {
        await mutate(api: api) { try await api.addVaultLogin(draft) }
    }

    func add(_ draft: VaultAPIKeyDraft, api: SettingsAPI) async -> Bool {
        await mutate(api: api) { try await api.addVaultAPIKey(draft) }
    }

    func update(_ draft: VaultEditDraft, api: SettingsAPI) async -> Bool {
        await mutate(api: api) { try await api.updateVaultItem(draft) }
    }

    func remove(_ entry: VaultEntry, api: SettingsAPI) async {
        _ = await mutate(api: api) { try await api.removeVaultItem(id: entry.id) }
    }

    private func mutate(api: SettingsAPI, _ operation: () async throws -> Void) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
            await load(api: api, surfacingFailure: true)
            return true
        } catch {
            actionFailure = SettingsFailure(error).message
            return false
        }
    }
}

struct VaultScreen: View {
    let hub: SettingsHub
    let profile: String?
    let back: () -> Void

    @State private var model: VaultModel
    @State private var adding = false
    @State private var editing: VaultEntry?
    @State private var selected: VaultEntry?
    @State private var choosingAction = false

    init(hub: SettingsHub, profile: String? = nil, back: @escaping () -> Void) {
        self.hub = hub
        self.profile = profile
        self.back = back
        _model = State(initialValue: VaultModel(surfaces: hub.connection.surfaces, profile: profile))
    }

    private var api: SettingsAPI { hub.api(for: profile) }

    var body: some View {
        SettingsPage(
            title: "Vault", identifier: "vaultScreen", back: back,
            trailing: {
                Button { adding = true } label: {
                    PalIcon("plus")
                }
                .accessibilityLabel(Text("Add to vault"))
                .accessibilityIdentifier("vaultAddButton")
            },
            content: {
                switch model.state {
                case .loading:
                    GroupedCard(accessibilityIdentifier: "vaultLoadingCard") {
                        LoadingRow(title: "Your vault", identifier: "vaultLoadingRow")
                    }
                case .failed(let message):
                    FailureCard(message: message, identifier: "vaultFailure") { Task { await model.load(api: api) } }
                case .loaded(let entries):
                    entriesCard(entries)
                }
            }
        )
        .task { await model.load(api: api) }
        .sheet(isPresented: $adding) {
            AddVaultSheet(model: model, api: api) { adding = false }
                .macSheetFrame()
        }
        .sheet(item: $editing) { entry in
            VaultEditSheet(model: model, api: api, entry: entry) { editing = nil }
                .macSheetFrame()
        }
        .alert("Vault", isPresented: Binding(get: { model.actionFailure != nil }, set: { if !$0 { model.actionFailure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionFailure ?? "")
        }
    }

    @ViewBuilder
    private func entriesCard(_ entries: [VaultEntry]) -> some View {
        GroupedCard(accessibilityIdentifier: "vaultCard") {
            if entries.isEmpty {
                PlaceholderRow("Your vault is empty", accessibilityIdentifier: "vaultEmptyRow")
            } else {
                ForEach(entries) { entry in
                    VaultEntryRow(entry: entry) {
                        selected = entry
                        choosingAction = true
                    }
                }
            }
        }
        .confirmationDialog(
            "Vault item", isPresented: $choosingAction, titleVisibility: .visible, presenting: selected
        ) { entry in
            if entry.isEditable {
                Button("Edit") { editing = entry }
                    .accessibilityIdentifier("vaultEditButton-\(entry.id)")
            }
            Button("Remove", role: .destructive) { Task { await model.remove(entry, api: api) } }
                .accessibilityIdentifier("vaultRemoveConfirm")
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text(entry.title)
        }
    }
}

private struct VaultEntryRow: View {
    let entry: VaultEntry
    let remove: () -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        LeadingSettingsRow(
            title: entry.title, subtitle: entry.subtitle, leadingSpacing: 14,
            accessibilityIdentifier: "vaultItem-\(entry.id)", action: entry.isRemovable ? remove : nil
        ) {
            PalIcon(entry.kind.symbolName, ink: .secondary)
                .font(.system(size: 17))
                .frame(width: 24)
                .accessibilityHidden(true)
        }
    }
}

private struct VaultFieldStyle: ViewModifier {
    @Environment(\.hermesTheme) private var theme

    func body(content: Content) -> some View {
        content
            .hermesText(.rowTitle)
            .foregroundStyle(Color(theme.palette.textPrimary))
            .padding(.horizontal, PalMetrics.rowInset)
            .frame(minHeight: PalMetrics.rowMinimumHeight)
    }
}

private struct VaultTextRow: View {
    let title: String
    let text: Binding<String>
    let identifier: String
    var content: PlatformTextContentType?

    var body: some View {
        TextField(title, text: text)
            .textContentType(content)
            .neverAutocapitalized()
            .autocorrectionDisabled()
            .modifier(VaultFieldStyle())
            .accessibilityIdentifier(identifier)
    }
}

private struct VaultPasswordRow: View {
    let title: String
    let text: Binding<String>
    let identifier: String

    var body: some View {
        SecureField(title, text: text)
            .textContentType(.oneTimeCode)
            .modifier(VaultFieldStyle())
            .accessibilityIdentifier(identifier)
    }
}

struct AddVaultSheet: View {
    private enum Choice: Hashable {
        case login
        case apiKey
    }

    let model: VaultModel
    let api: SettingsAPI
    let close: () -> Void

    @State private var choice = Choice.login
    @State private var login = VaultLoginDraft()
    @State private var apiKey = VaultAPIKeyDraft()

    private var isComplete: Bool { choice == .login ? login.isComplete : apiKey.isComplete }

    var body: some View {
        SheetChrome(
            title: choice == .login ? "Add Login" : "Add API Key", accessibilityIdentifier: "vaultAddSheet", onLeading: close,
            trailing: {
                PillButton(
                    "Save", kind: isComplete ? .accent : .dimmed, isBusy: model.isBusy,
                    accessibilityIdentifier: "vaultSaveButton"
                ) {
                    Task {
                        if await save() {
                            login.password = ""
                            apiKey.apiKey = ""
                            close()
                        }
                    }
                }
            },
            content: {
                ScrollView {
                    VStack(alignment: .leading, spacing: PalMetrics.cardGap) {
                        Picker("Kind", selection: $choice) {
                            Text("Login").tag(Choice.login)
                            Text("API key").tag(Choice.apiKey)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding(.horizontal, PalMetrics.screenMargin)
                        .accessibilityIdentifier("vaultKindPicker")
                        GroupedCard(accessibilityIdentifier: "vaultAddFields") {
                            if choice == .login {
                                VaultTextRow(title: "Name", text: $login.label, identifier: "vaultNameField")
                                VaultTextRow(title: "Website", text: $login.website, identifier: "vaultWebsiteField", content: .URL)
                                VaultTextRow(title: "Email, phone or username", text: $login.identifier, identifier: "vaultIdentifierField")
                                VaultPasswordRow(title: "Password", text: $login.password, identifier: "vaultPasswordField")
                            } else {
                                VaultTextRow(title: "Name", text: $apiKey.label, identifier: "vaultNameField")
                                SecretField("API key", text: $apiKey.apiKey, identifier: "vaultAPIKeyField")
                                    .modifier(VaultFieldStyle())
                            }
                        }
                        CardFootnote(
                            choice == .login
                                ? "Passwords are stored encrypted on the computer that runs Pal. Your Bots can use them but never read them."
                                : "API keys are stored encrypted on the computer that runs Pal. Your Bots can use them but never read them.",
                            accessibilityIdentifier: "vaultAddFootnote"
                        )
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
        )
    }

    private func save() async -> Bool {
        switch choice {
        case .login: await model.add(login, api: api)
        case .apiKey: await model.add(apiKey, api: api)
        }
    }
}

struct VaultEditSheet: View {
    let model: VaultModel
    let api: SettingsAPI
    let close: () -> Void

    @State private var draft: VaultEditDraft

    init(model: VaultModel, api: SettingsAPI, entry: VaultEntry, close: @escaping () -> Void) {
        self.model = model
        self.api = api
        self.close = close
        _draft = State(initialValue: VaultEditDraft(entry: entry))
    }

    var body: some View {
        SheetChrome(
            title: "Edit", accessibilityIdentifier: "vaultEditSheet", onLeading: close,
            trailing: {
                PillButton(
                    "Save", kind: draft.isComplete ? .accent : .dimmed, isBusy: model.isBusy,
                    accessibilityIdentifier: "vaultEditSaveButton"
                ) {
                    Task {
                        if await model.update(draft, api: api) {
                            draft.secret = ""
                            close()
                        }
                    }
                }
            },
            content: {
                ScrollView {
                    VStack(alignment: .leading, spacing: PalMetrics.cardGap) {
                        GroupedCard(accessibilityIdentifier: "vaultEditFields") {
                            VaultTextRow(title: "Name", text: $draft.label, identifier: "vaultNameField")
                            switch draft.kind {
                            case .login:
                                VaultTextRow(title: "Website", text: $draft.website, identifier: "vaultWebsiteField", content: .URL)
                                VaultTextRow(title: "Email, phone or username", text: $draft.identifier, identifier: "vaultIdentifierField")
                                VaultPasswordRow(title: "Password", text: $draft.secret, identifier: "vaultPasswordField")
                            case .apiKey:
                                SecretField("API key", text: $draft.secret, identifier: "vaultAPIKeyField")
                                    .modifier(VaultFieldStyle())
                            case .payment, .address, .other:
                                EmptyView()
                            }
                        }
                        if let footnote {
                            CardFootnote(footnote, accessibilityIdentifier: "vaultEditFootnote")
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
        )
    }

    private var footnote: String? {
        switch draft.kind {
        case .login: "Leave the password blank to keep the current one."
        case .apiKey: "Leave the API key blank to keep the current one."
        case .payment, .address, .other: nil
        }
    }
}
