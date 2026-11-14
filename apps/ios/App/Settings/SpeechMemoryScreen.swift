import PalBotProfile
import PalDesign
import PalProtocol
import SwiftUI

struct SpeechMemoryScreen: View {
    let hub: SettingsHub
    let back: () -> Void

    @Environment(\.hermesTheme) private var theme
    @State private var model: SpeechMemoryModel
    private let botName: String

    init(hub: SettingsHub, back: @escaping () -> Void) {
        self.hub = hub
        self.back = back
        let connection = hub.connection
        let profile = hub.roster.bots.first(where: \.isDefault)?.name ?? ""
        botName = profile
        let gateway = BotsGateway { method, params in try await connection.rpc(method, params) }
        _model = State(initialValue: SpeechMemoryModel(client: SpeechMemoryClient(gateway: gateway, profile: profile), profile: profile, surfaces: connection.surfaces))
    }

    var body: some View {
        SettingsPage(title: "Voice and memory", identifier: "speechMemoryScreen", back: back) {
            content
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(
            item: Binding(get: { model.keyEntry }, set: { if $0 == nil { model.cancelKeyEntry() } })
        ) { target in
            keyEntrySheet(target)
        }
        .confirmationDialog(
            "Remove this key?",
            isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: model.pendingRemoval
        ) { target in
            Button("Remove", role: .destructive) { Task { await model.remove(target) } }
                .accessibilityIdentifier("speechMemoryRemoveConfirm")
            Button("Cancel", role: .cancel) { model.pendingRemoval = nil }
        } message: { target in
            Text("\(target.provider.name) stops working until you set a key again.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let settings = model.settings {
            areaSection(.tts, title: "Voice", group: settings.tts)
            areaSection(.memory, title: "Memory", group: settings.memory)
            CardFootnote(
                model.loadFailed ? "Couldn't refresh. Pull to try again." : "Keys are never shown after you save them. Changes apply to new chats.",
                accessibilityIdentifier: "speechMemoryFootnote")
        } else if model.loadFailed {
            FailureCard(message: "Couldn't load your voice and memory settings.", identifier: "speechMemoryFailure") {
                Task { await model.load() }
            }
        } else {
            GroupedCard(accessibilityIdentifier: "speechMemoryLoading") {
                LoadingRow(title: "Voice and memory", identifier: "speechMemoryLoadingRow")
            }
        }
    }

    private func areaSection(_ area: SpeechMemoryArea, title: String, group: SpeechProviderGroup) -> some View {
        let key = "speechMemory-\(area.rawValue)"
        return VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
            SectionCaption(title, accessibilityIdentifier: "\(key)-caption")
            GroupedCard(accessibilityIdentifier: key) {
                providerPicker(area, group: group, key: key)
                if let voice = group.voice, group.selected == "edge" {
                    voicePicker(voice, key: key)
                }
            }
            choiceStatus(area, key: key)
            ForEach(group.providers.filter { $0.keyName != nil }) { provider in
                keySection(area, provider: provider)
            }
        }
    }

    private func providerPicker(_ area: SpeechMemoryArea, group: SpeechProviderGroup, key: String) -> some View {
        Picker(
            "Provider",
            selection: Binding(
                get: { group.selected.isEmpty && area == .tts ? "edge" : group.selected },
                set: { choice in Task { await model.choose(area, provider: choice) } })
        ) {
            if area == .memory { Text("Built-in only").tag("") }
            ForEach(group.providers) { provider in Text(provider.name).tag(provider.id) }
        }
        .pickerStyle(.menu)
        .padding(.horizontal, PalMetrics.rowInset)
        .frame(minHeight: PalMetrics.rowMinimumHeight)
        .disabled(model.choice(area) == .working(.choosing))
        .accessibilityIdentifier("\(key)-provider")
    }

    private func voicePicker(_ voice: SpeechVoice, key: String) -> some View {
        Picker(
            "Voice",
            selection: Binding(
                get: { voice.current },
                set: { choice in Task { await model.choose(.tts, provider: "edge", voice: choice) } })
        ) {
            ForEach(voice.options) { option in Text(option.label).tag(option.id) }
        }
        .pickerStyle(.menu)
        .padding(.horizontal, PalMetrics.rowInset)
        .frame(minHeight: PalMetrics.rowMinimumHeight)
        .disabled(model.choice(.tts) == .working(.choosing))
        .accessibilityIdentifier("\(key)-voice")
    }

    @ViewBuilder
    private func choiceStatus(_ area: SpeechMemoryArea, key: String) -> some View {
        statusLine(model.choice(area), identifier: "\(key)-choice-status", working: "Saving…")
    }

    private func keySection(_ area: SpeechMemoryArea, provider: SpeechMemoryProvider) -> some View {
        let key = "speechMemory-\(area.rawValue)-\(provider.id)"
        let target = SpeechMemoryModel.Target(area: area, provider: provider)
        let busy = model.isWorking(area, provider.id)
        return VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
            GroupedCard(accessibilityIdentifier: key) {
                SettingsRow.value(
                    "\(provider.name) key", value: provider.statusWord, subtitle: provider.note, accessibilityIdentifier: "\(key)-state")
                SettingsRow(
                    title: provider.keySet ? "Replace key" : "Set key", trailing: .none, accessibilityIdentifier: "\(key)-set",
                    action: { model.beginKeyEntry(target) }
                )
                .disabled(busy)
                if provider.canRemove {
                    SettingsRow.destructive("Remove key", accessibilityIdentifier: "\(key)-remove") { model.pendingRemoval = target }
                        .disabled(busy)
                }
            }
            statusLine(model.status(area, provider.id), identifier: "\(key)-status", working: "Removing…")
        }
    }

    @ViewBuilder
    private func statusLine(_ status: SpeechMemoryModel.RowStatus, identifier: String, working: String) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .working:
            CardFootnote(working, accessibilityIdentifier: identifier)
        case .succeeded(let text):
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

    private func keyEntrySheet(_ target: SpeechMemoryModel.Target) -> some View {
        let name = target.provider.keyName ?? target.provider.name
        return SecretEntryView(
            connectorName: target.provider.name,
            accountLabel: botName,
            purpose: String(localized: "Paste the key for \(name). It is saved for your bot only and can't be read back."),
            fieldLabel: name,
            state: entryState,
            identifiers: SecretEntryIdentifiers(
                field: "speech-memory-key-field", submit: "speech-memory-key-save-button",
                cancel: "speech-memory-key-cancel-button", status: "speech-memory-key-status"
            ),
            onSubmit: { value in Task { await model.submitKey(value) } },
            onCancel: { model.cancelKeyEntry() }
        )
        .padding(24)
        .presentationDetents([.medium])
        .macSheetFrame()
    }

    private var entryState: SecretEntryState {
        switch model.keyEntryState {
        case .idle: .idle
        case .submitting: .submitting
        case .failed(let text): .failure(text)
        }
    }
}
