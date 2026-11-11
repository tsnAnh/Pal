import HermesDesign
import HermesSettings
import Observation
import SwiftUI

@MainActor
@Observable
final class VaultModel {
    private(set) var state: Loadable<[VaultEntry]> = .loading
    private(set) var isBusy = false
    var actionFailure: String?

    func load(api: SettingsAPI) async {
        do {
            state = .loaded(try await api.vaultItems().map(VaultEntry.init))
        } catch is CancellationError {
            return
        } catch {
            state = .failed(SettingsFailure(error).message)
        }
    }

    func add(_ draft: VaultLoginDraft, api: SettingsAPI) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            try await api.addVaultLogin(draft)
            await load(api: api)
            return true
        } catch {
            actionFailure = SettingsFailure(error).message
            return false
        }
    }

    func remove(_ entry: VaultEntry, api: SettingsAPI) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await api.removeVaultItem(id: entry.id)
            await load(api: api)
        } catch {
            actionFailure = SettingsFailure(error).message
        }
    }
}

struct VaultScreen: View {
    let hub: SettingsHub
    let back: () -> Void

    @State private var model = VaultModel()
    @State private var adding = false
    @State private var removing: VaultEntry?
    @State private var confirmingRemoval = false

    var body: some View {
        SettingsPage(
            title: "Vault", identifier: "vaultScreen", back: back,
            trailing: {
                Button { adding = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(Text("Add to vault"))
                .accessibilityIdentifier("vaultAddButton")
                .tint(.primary)
            },
            content: {
                switch model.state {
                case .loading:
                    GroupedCard(accessibilityIdentifier: "vaultLoadingCard") {
                        LoadingRow(title: "Your vault", identifier: "vaultLoadingRow")
                    }
                case .failed(let message):
                    FailureCard(message: message, identifier: "vaultFailure") { Task { await model.load(api: hub.api) } }
                case .loaded(let entries):
                    entriesCard(entries)
                }
            }
        )
        .task { await model.load(api: hub.api) }
        .sheet(isPresented: $adding) {
            AddVaultLoginSheet(model: model, hub: hub) { adding = false }
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
                        removing = entry
                        confirmingRemoval = true
                    }
                }
            }
        }
        .confirmationDialog(
            "Remove this item from your vault?", isPresented: $confirmingRemoval, titleVisibility: .visible, presenting: removing
        ) { entry in
            Button("Remove", role: .destructive) { Task { await model.remove(entry, api: hub.api) } }
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
            Image(systemName: entry.kind.symbolName)
                .font(.system(size: 17))
                .foregroundStyle(Color(theme.palette.textSecondary))
                .frame(width: 24)
                .accessibilityHidden(true)
        }
    }
}

struct AddVaultLoginSheet: View {
    let model: VaultModel
    let hub: SettingsHub
    let close: () -> Void

    @State private var draft = VaultLoginDraft()
    @Environment(\.hermesTheme) private var theme

    var body: some View {
        SheetChrome(
            title: "Add Login", accessibilityIdentifier: "vaultAddSheet", onLeading: close,
            trailing: {
                PillButton(
                    "Save", kind: draft.isComplete ? .accent : .dimmed, isBusy: model.isBusy,
                    accessibilityIdentifier: "vaultSaveButton"
                ) {
                    Task {
                        if await model.add(draft, api: hub.api) {
                            draft.password = ""
                            close()
                        }
                    }
                }
            },
            content: {
                ScrollView {
                    VStack(alignment: .leading, spacing: HermesMetrics.cardGap) {
                        GroupedCard(accessibilityIdentifier: "vaultAddFields") {
                            field("Name", text: $draft.label, identifier: "vaultNameField", content: .none)
                            field("Website", text: $draft.website, identifier: "vaultWebsiteField", content: .URL)
                            field("Email, phone or username", text: $draft.identifier, identifier: "vaultIdentifierField", content: .none)
                            secureField
                        }
                        CardFootnote(
                            "Passwords are stored encrypted on the computer that runs Pal. Your Bots can use them but never read them.",
                            accessibilityIdentifier: "vaultAddFootnote"
                        )
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
        )
    }

    private func field(_ title: String, text: Binding<String>, identifier: String, content: PlatformTextContentType?) -> some View {
        TextField(title, text: text)
            .textContentType(content)
            .neverAutocapitalized()
            .autocorrectionDisabled()
            .hermesText(.rowTitle)
            .foregroundStyle(Color(theme.palette.textPrimary))
            .padding(.horizontal, HermesMetrics.rowInset)
            .frame(minHeight: HermesMetrics.rowMinimumHeight)
            .accessibilityIdentifier(identifier)
    }

    private var secureField: some View {
        SecureField("Password", text: $draft.password)
            .textContentType(.oneTimeCode)
            .hermesText(.rowTitle)
            .foregroundStyle(Color(theme.palette.textPrimary))
            .padding(.horizontal, HermesMetrics.rowInset)
            .frame(minHeight: HermesMetrics.rowMinimumHeight)
            .accessibilityIdentifier("vaultPasswordField")
    }
}
