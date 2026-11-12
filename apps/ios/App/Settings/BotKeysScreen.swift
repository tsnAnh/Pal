import PalBotProfile
import PalDesign
import SwiftUI

struct BotKeysScreen: View {
    @State private var model: BotKeysModel
    let displayName: String

    @Environment(\.hermesTheme) private var theme

    init(model: BotKeysModel, displayName: String) {
        _model = State(initialValue: model)
        self.displayName = displayName
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PalMetrics.cardGap) {
                content
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(Color(theme.palette.sheetBackground).ignoresSafeArea())
        .accessibilityIdentifier("botKeysScreen")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Keys")
                    .hermesText(.sheetTitle)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .accessibilityAddTraits(.isHeader)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .toolbarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(item: Binding(get: { model.entry }, set: { if $0 == nil { model.cancel() } })) { row in
            entrySheet(row)
        }
        .confirmationDialog(
            "Remove this key?",
            isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: model.pendingRemoval
        ) { row in
            Button("Remove", role: .destructive) { Task { await model.remove(row) } }
                .accessibilityIdentifier("botKeysRemoveConfirm")
            Button("Cancel", role: .cancel) { model.pendingRemoval = nil }
        } message: { row in
            Text("\(row.label) stops working for \(displayName) until you set a key again.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity).padding(.top, 24).accessibilityIdentifier("botKeysLoading")
        case .failed:
            FailureCard(message: "Couldn't load this bot's keys.", identifier: "botKeysFailure") {
                Task { await model.load() }
            }
        case .ready:
            ForEach(model.groups) { group in
                section(group)
            }
            CardFootnote(
                "Keys are never shown after you save them. A new key applies to new chats.",
                accessibilityIdentifier: "botKeysFootnote")
        }
    }

    private func section(_ group: BotKeyGroup) -> some View {
        VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
            SectionCaption(group.label, accessibilityIdentifier: "botKeysCaption-\(group.id)")
            ForEach(group.keys) { row in
                keyCard(row)
            }
        }
    }

    private func keyCard(_ row: BotKeyRow) -> some View {
        let key = "botKeys-\(row.name)"
        let busy = model.isWorking(row)
        return VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
            GroupedCard(accessibilityIdentifier: key) {
                SettingsRow.value(row.label, value: row.statusWord, subtitle: row.name, accessibilityIdentifier: "\(key)-state")
                SettingsRow(
                    title: row.isSet ? "Replace" : "Set key", trailing: .none, accessibilityIdentifier: "\(key)-set",
                    action: { model.begin(row) }
                )
                .disabled(busy)
                if row.isSet {
                    SettingsRow.destructive("Remove", accessibilityIdentifier: "\(key)-remove") { model.pendingRemoval = row }
                        .disabled(busy)
                }
            }
            noticeLine(model.notice(row), identifier: "\(key)-status")
        }
    }

    @ViewBuilder
    private func noticeLine(_ notice: BotKeysModel.Notice?, identifier: String) -> some View {
        switch notice {
        case nil:
            EmptyView()
        case .working(let text), .saved(let text):
            CardFootnote(text, accessibilityIdentifier: identifier)
        case .failed(let text):
            Text(text)
                .hermesText(.rowSubtitle)
                .foregroundStyle(Color(theme.palette.destructive))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PalMetrics.screenMargin + PalMetrics.rowInset - 3)
                .accessibilityIdentifier(identifier)
        }
    }

    private func entrySheet(_ row: BotKeyRow) -> some View {
        SecretEntryView(
            connectorName: row.label,
            accountLabel: displayName,
            purpose: String(localized: "Paste the key for \(row.name). It is saved for \(displayName) only and can't be read back."),
            fieldLabel: row.name,
            state: entryState,
            identifiers: SecretEntryIdentifiers(
                field: "bot-key-field", submit: "bot-key-save-button",
                cancel: "bot-key-cancel-button", status: "bot-key-status"
            ),
            onSubmit: { value in Task { await model.submit(value) } },
            onCancel: { model.cancel() }
        )
        .padding(24)
        .presentationDetents([.medium])
        .macSheetFrame()
    }

    private var entryState: SecretEntryState {
        switch model.entryState {
        case .idle: .idle
        case .submitting: .submitting
        case .failed(let text): .failure(text)
        }
    }
}
