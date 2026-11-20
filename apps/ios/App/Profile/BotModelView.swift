import PalBotProfile
import PalDesign
import SwiftUI

struct BotModelView: View {
    private enum Picking: Identifiable {
        case primary
        case fallback

        var id: Self { self }
    }

    @State private var model: BotModelsModel
    @State private var picking: Picking?
    @State private var addingKey = false
    let displayName: String
    @Environment(\.hermesTheme) private var theme
    @Environment(SettingsHub.self) private var hub

    init(model: BotModelsModel, displayName: String) {
        _model = State(initialValue: model)
        self.displayName = displayName
    }

    private var depth: Int { (picking == nil ? 0 : 1) + (addingKey ? 1 : 0) }

    private var title: String {
        if addingKey { return String(localized: "Add a key") }
        switch picking {
        case .primary: return String(localized: "Choose a model")
        case .fallback: return String(localized: "Add a backup model")
        case nil: return String(localized: "Model, effort and backups")
        }
    }

    private func goBack() {
        if addingKey {
            addingKey = false
            Task { await model.load() }
        } else {
            picking = nil
        }
    }

    var body: some View {
        BotSettingsScreen(title: title, identifier: "botModelScreen", depth: depth, back: goBack) {
            stepContent
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        #if os(iOS)
        .sheet(item: $picking) { mode in
            BotModelPicker(model: model, mode: mode == .primary ? .primary : .fallback, addKey: {}, finish: { picking = nil })
        }
        #endif
        .confirmationDialog(
            "Use this model?",
            isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } }),
            titleVisibility: .visible,
            presenting: model.confirmation
        ) { _ in
            Button("Use model") { Task { await model.confirmPending() } }
                .accessibilityIdentifier("botModelConfirm")
            Button("Cancel", role: .cancel) { model.confirmation = nil }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        #if os(macOS)
        if addingKey {
            MacModelProvidersSection(hub: hub, embedded: true)
        } else if let mode = picking {
            BotModelPicker(model: model, mode: mode == .primary ? .primary : .fallback, addKey: { addingKey = true }, finish: { picking = nil })
        } else {
            phaseContent
        }
        #else
        phaseContent
        #endif
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch model.phase {
        case .loading:
            DelayedProgressView().padding(.top, 40).accessibilityIdentifier("botModelLoading")
        case .failed:
            FailureCard(message: "Couldn't load this bot's models.", identifier: "botModelFailure") {
                Task { await model.load() }
            }
        case .ready:
            overview
        }
    }

    @ViewBuilder
    private var overview: some View {
        GroupedCard(accessibilityIdentifier: "botModelCard") {
            SettingsRow.navigate(
                String(localized: "Model"),
                subtitle: model.settings.current.map { model.providerName(for: $0) },
                value: model.currentText ?? String(localized: "Not set"),
                accessibilityIdentifier: "botModelRow"
            ) { picking = .primary }
            .disabled(model.isSaving)
        }
        effortSection
        SectionCaption(String(localized: "Backup models"), accessibilityIdentifier: "botFallbackCaption")
            .padding(.top, PalMetrics.cardGap)
            .padding(.bottom, PalMetrics.captionToCardGap)
        GroupedCard(accessibilityIdentifier: "botFallbackCard") {
            ForEach(model.settings.fallbacks) { choice in
                fallbackRow(choice)
            }
            SettingsRow.navigate(
                String(localized: "Add a backup model"),
                accessibilityIdentifier: "botFallbackAdd"
            ) { picking = .fallback }
            .disabled(model.isSaving)
        }
        CardFootnote(
            String(localized: "If \(displayName)'s model fails, these are tried in order."),
            accessibilityIdentifier: "botFallbackFootnote")
        statusLine
    }

    @ViewBuilder
    private var effortSection: some View {
        SectionCaption(String(localized: "Reasoning effort"), accessibilityIdentifier: "botEffortCaption")
            .padding(.top, PalMetrics.cardGap)
            .padding(.bottom, PalMetrics.captionToCardGap)
        GroupedCard(accessibilityIdentifier: "botEffortCard") {
            switch model.effortOptions {
            case .levels:
                effortMenu(model.effortChoices ?? [])
            case .unsupported:
                SettingsRow.value(
                    String(localized: "Effort"), value: String(localized: "Not supported"),
                    subtitle: String(localized: "This model doesn't use reasoning effort."),
                    accessibilityIdentifier: "botEffortRow")
            case .unknown:
                SettingsRow.value(
                    String(localized: "Effort"), value: ReasoningEffort.title(model.effort),
                    subtitle: String(localized: "Pal can't tell which levels this model supports."),
                    accessibilityIdentifier: "botEffortRow")
            }
        }
        CardFootnote(
            String(localized: "Applies to new conversations. Ones already open keep their effort."),
            accessibilityIdentifier: "botEffortFootnote")
    }

    private func effortMenu(_ levels: [String]) -> some View {
        let selection = Binding<String>(
            get: { model.effort ?? "" },
            set: { level in Task { await model.chooseEffort(level) } })
        return Menu {
            Picker(String(localized: "Reasoning effort"), selection: selection) {
                ForEach(levels, id: \.self) { level in
                    Text(ReasoningEffort.title(level)).tag(level)
                }
            }
        } label: {
            SettingsRow.value(
                String(localized: "Effort"), value: ReasoningEffort.title(model.effort),
                accessibilityIdentifier: "botEffortRow")
        }
        .disabled(model.isSaving)
    }

    private func fallbackRow(_ choice: ModelChoice) -> some View {
        let index = model.settings.fallbacks.firstIndex(of: choice) ?? 0
        let last = model.settings.fallbacks.count - 1
        return HStack(spacing: 4) {
            SettingsRow(
                title: model.displayName(for: choice),
                subtitle: "\(index + 1). \(model.providerName(for: choice))",
                accessibilityIdentifier: "botFallbackRow-\(choice.id)")
            fallbackButton("chevron.up", label: "Move up", id: "up", choice: choice, disabled: index == 0) {
                await model.moveFallback(choice, by: -1)
            }
            fallbackButton("chevron.down", label: "Move down", id: "down", choice: choice, disabled: index == last) {
                await model.moveFallback(choice, by: 1)
            }
            fallbackButton("minus.circle", label: "Remove", id: "remove", choice: choice, disabled: false) {
                await model.removeFallback(choice)
            }
        }
        .padding(.trailing, PalMetrics.rowInset)
    }

    private func fallbackButton(
        _ symbol: String, label: LocalizedStringKey, id: String, choice: ModelChoice, disabled: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        Button { Task { await action() } } label: {
            PalIcon(symbol, ink: .secondary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(disabled || model.isSaving)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier("botFallback-\(id)-\(choice.id)")
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.save {
        case .idle:
            EmptyView()
        case .saving:
            CardFootnote(String(localized: "Saving…"), accessibilityIdentifier: "botModelStatus")
        case .saved(let text):
            CardFootnote(text, accessibilityIdentifier: "botModelStatus")
        case .failed(let text):
            Text(text)
                .hermesText(.rowSubtitle)
                .foregroundStyle(Color(theme.palette.destructive))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PalMetrics.screenMargin + PalMetrics.rowInset - 3)
                .padding(.top, PalMetrics.captionToCardGap)
                .accessibilityIdentifier("botModelStatus")
        }
    }
}

private struct BotModelPicker: View {
    enum Mode {
        case primary
        case fallback
    }

    let model: BotModelsModel
    let mode: Mode
    let addKey: () -> Void
    let finish: () -> Void

    @State private var query = ""
    @State private var showsKeys = false
    @Environment(SettingsHub.self) private var hub
    @Environment(\.hermesTheme) private var theme

    var body: some View {
        #if os(macOS)
        list.accessibilityIdentifier("botModelPicker")
        #else
        SheetChrome(
            title: mode == .primary ? String(localized: "Choose a model") : String(localized: "Add a backup model"),
            accessibilityIdentifier: "botModelPicker",
            leadingAccessibilityIdentifier: "botModelPickerCancel",
            onLeading: finish
        ) {
            ScrollView {
                list
                    .padding(.top, 16)
            }
        }
        .sheet(isPresented: $showsKeys, onDismiss: { Task { await model.load() } }) {
            NavigationStack {
                ModelProvidersScreen(hub: hub) { showsKeys = false }
            }
            .serviceSignInDialogHost()
        }
        #endif
    }

    private func requestKey() {
        #if os(macOS)
        addKey()
        #else
        showsKeys = true
        #endif
    }

    private var list: some View {
        VStack(spacing: 0) {
            TextField("Search models", text: $query)
                .textFieldStyle(.plain)
                .padding(.horizontal, PalMetrics.rowInset)
                .frame(minHeight: PalMetrics.rowMinimumHeight)
                .background(Color(theme.palette.groupedCard), in: Capsule())
                .padding(.horizontal, PalMetrics.screenMargin)
                .accessibilityIdentifier("botModelSearch")
            let matches = model.models(matching: query)
            ForEach(matches) { provider in
                SectionCaption(provider.name, accessibilityIdentifier: "botModelProvider-\(provider.id)")
                    .padding(.top, PalMetrics.cardGap)
                    .padding(.bottom, PalMetrics.captionToCardGap)
                GroupedCard(accessibilityIdentifier: "botModelProviderCard-\(provider.id)") {
                    ForEach(provider.models, id: \.self) { name in
                        let choice = ModelChoice(provider: provider.id, model: name)
                        SettingsRow(
                            title: name,
                            trailing: .none,
                            icon: isMarked(choice) ? RowIcon.symbol("checkmark") : nil,
                            accessibilityIdentifier: "botModelOption-\(choice.id)"
                        ) {
                            pick(choice)
                        }
                    }
                }
            }
            if matches.isEmpty {
                CardFootnote(String(localized: "No models match."), accessibilityIdentifier: "botModelNoMatch")
                    .padding(.top, PalMetrics.cardGap)
            }
            let locked = model.providersNeedingKey
            if !locked.isEmpty {
                SectionCaption(String(localized: "Needs a key"), accessibilityIdentifier: "botModelKeyCaption")
                    .padding(.top, PalMetrics.cardGap)
                    .padding(.bottom, PalMetrics.captionToCardGap)
                GroupedCard(accessibilityIdentifier: "botModelKeyCard") {
                    ForEach(locked) { provider in
                        SettingsRow.navigate(
                            provider.name,
                            value: String(localized: "Add a key"),
                            accessibilityIdentifier: "botModelAddKey-\(provider.id)"
                        ) { requestKey() }
                    }
                }
            }
        }
    }

    private func isMarked(_ choice: ModelChoice) -> Bool {
        switch mode {
        case .primary: model.settings.current == choice
        case .fallback: model.settings.fallbacks.contains(choice)
        }
    }

    private func pick(_ choice: ModelChoice) {
        finish()
        Task {
            switch mode {
            case .primary: await model.choose(choice)
            case .fallback: await model.addFallback(choice)
            }
        }
    }
}
