import HermesDesign
import HermesProtocol
import HermesSettings
import Observation
import SwiftUI

struct AppearanceScreen: View {
    let back: () -> Void

    @Environment(AppearanceStore.self) private var appearance

    private static let top: [AppearanceMode] = [.followSystem, .light, .dark]
    private static let bottom: [AppearanceMode] = [.black, .botColor]

    private static func icon(for mode: AppearanceMode) -> AppearanceTileIcon {
        switch mode {
        case .followSystem: .followSystem
        case .light: .light
        case .dark: .dark
        case .black: .black
        case .botColor: .botColor
        }
    }

    var body: some View {
        SettingsPage(title: "Appearance", identifier: "appearanceScreen", surface: .canvas, back: back) {
            VStack(spacing: HermesMetrics.appearanceRowSpacing) {
                row(Self.top)
                row(Self.bottom)
            }
            .padding(.horizontal, HermesMetrics.screenMargin)
        }
    }

    private func row(_ modes: [AppearanceMode]) -> some View {
        HStack(alignment: .top, spacing: HermesMetrics.appearanceTileSpacing) {
            ForEach(modes) { mode in
                AppearanceTile(
                    title: mode.title, icon: Self.icon(for: mode), isSelected: appearance.mode == mode,
                    accessibilityIdentifier: "appearanceMode-\(mode.rawValue)"
                ) {
                    guard appearance.mode != mode else { return }
                    SettingsHaptics.selection()
                    appearance.mode = mode
                }
            }
        }
    }
}

struct HapticsScreen: View {
    let back: () -> Void

    @AppStorage(SettingsDefaults.hapticsKey) private var enabled = true

    var body: some View {
        SettingsPage(title: "Haptics", identifier: "hapticsScreen", back: back) {
            VStack(alignment: .leading, spacing: HermesMetrics.captionToCardGap) {
                GroupedCard(accessibilityIdentifier: "hapticsCard") {
                    SettingsRow.toggle(
                        "Haptics", subtitle: "Feel a tap when you change a setting.",
                        isOn: Binding(
                            get: { enabled },
                            set: { value in
                                enabled = value
                                SettingsHaptics.selection()
                            }
                        ),
                        accessibilityIdentifier: "hapticsToggle"
                    )
                }
            }
        }
    }
}

@MainActor
@Observable
final class DataSharingModel {
    private(set) var state: Loadable<SettingsWire.SharedMetrics> = .loading
    var failure: String?

    func load(api: SettingsAPI) async {
        do {
            state = .loaded(try await api.sharedMetrics())
        } catch is CancellationError {
            return
        } catch {
            state = .failed(SettingsFailure(error).message)
        }
    }

    func set(enabled: Bool, send: Bool, api: SettingsAPI) async {
        do {
            state = .loaded(try await api.setSharedMetrics(enabled: enabled, send: send))
        } catch {
            failure = SettingsFailure(error).message
            await load(api: api)
        }
    }
}

struct DataSharingScreen: View {
    let hub: SettingsHub
    let back: () -> Void

    @State private var model = DataSharingModel()

    var body: some View {
        SettingsPage(title: "Data sharing", identifier: "dataSharingScreen", back: back) {
            switch model.state {
            case .loading:
                GroupedCard(accessibilityIdentifier: "dataSharingLoading") {
                    LoadingRow(title: "Data sharing", identifier: "dataSharingLoadingRow")
                }
            case .failed(let message):
                FailureCard(message: message, identifier: "dataSharingFailure") { Task { await model.load(api: hub.api) } }
            case .loaded(let metrics):
                VStack(alignment: .leading, spacing: HermesMetrics.captionToCardGap) {
                    GroupedCard(accessibilityIdentifier: "dataSharingCard") {
                        SettingsRow.toggle(
                            "Share usage data", subtitle: "Help improve Hermes with anonymous usage information.",
                            isOn: Binding(
                                get: { metrics.enabled },
                                set: { value in Task { await model.set(enabled: value, send: metrics.send, api: hub.api) } }
                            ),
                            accessibilityIdentifier: "dataSharingEnabledToggle"
                        )
                        SettingsRow.toggle(
                            "Send reports automatically", subtitle: "Upload the shared usage data to Hermes.",
                            isOn: Binding(
                                get: { metrics.enabled && metrics.send },
                                set: { value in Task { await model.set(enabled: metrics.enabled, send: value, api: hub.api) } }
                            ),
                            accessibilityIdentifier: "dataSharingSendToggle"
                        )
                        .disabled(!metrics.enabled)
                        .opacity(metrics.enabled ? 1 : 0.5)
                    }
                    CardFootnote("Your conversations are never part of this data.", accessibilityIdentifier: "dataSharingFootnote")
                }
            }
        }
        .task { await model.load(api: hub.api) }
        .alert("Data sharing", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.failure ?? "")
        }
    }
}

struct TimeZoneScreen: View {
    let hub: SettingsHub
    let back: () -> Void

    @State private var query = ""
    @Environment(\.hermesTheme) private var theme

    private static let identifiers = TimeZone.knownTimeZoneIdentifiers.sorted()

    private var matches: [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return Self.identifiers }
        return Self.identifiers.filter { TimeZoneNames.display($0).localizedStandardContains(needle) }
    }

    var body: some View {
        SheetChrome(
            title: "Time Zone", leading: .back, accessibilityIdentifier: "timeZoneScreen", onLeading: back
        ) {
            VStack(spacing: 12) {
                TextField("Search time zones", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .hermesText(.rowTitle)
                    .padding(.horizontal, HermesMetrics.rowInset)
                    .frame(minHeight: HermesMetrics.rowMinimumHeight)
                    .background(Color(theme.palette.groupedCard), in: RoundedRectangle(cornerRadius: HermesMetrics.cardRadius, style: .continuous))
                    .padding(.horizontal, HermesMetrics.screenMargin)
                    .accessibilityIdentifier("timeZoneSearch")
                List(matches, id: \.self) { identifier in
                    Button {
                        Task {
                            await hub.setTimeZone(identifier)
                            back()
                        }
                    } label: {
                        HStack {
                            Text(TimeZoneNames.display(identifier))
                                .hermesText(.rowTitle)
                                .foregroundStyle(Color(theme.palette.textPrimary))
                            Spacer()
                            if identifier == hub.aboutYou?.timezone {
                                Image(systemName: "checkmark").foregroundStyle(Color(theme.palette.textPrimary))
                            }
                        }
                    }
                    .listRowBackground(Color(theme.palette.groupedCard))
                    .listRowSeparatorTint(Color(theme.palette.separator))
                    .accessibilityIdentifier("timeZone-\(identifier)")
                }
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("timeZoneList")
            }
        }
    }
}

@MainActor
@Observable
final class MemoryImportModel {
    var text = ""
    private(set) var isBusy = false
    private(set) var result: String?
    var failure: String?

    var canImport: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isBusy }

    func run(api: SettingsAPI) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let summary = MemoryImportSummary(try await api.importMemory(text))
            result = summary.text
            if summary.added > 0 { text = "" }
        } catch {
            failure = SettingsFailure(error).message
        }
    }
}

struct ImportMemoryScreen: View {
    let hub: SettingsHub
    let back: () -> Void

    @State private var model = MemoryImportModel()
    @FocusState private var focused: Bool
    @Environment(\.hermesTheme) private var theme

    var body: some View {
        SettingsPage(title: "Import Memory", identifier: "importMemoryScreen", back: back) {
            VStack(alignment: .leading, spacing: HermesMetrics.captionToCardGap) {
                GroupedCard(accessibilityIdentifier: "importMemoryCard") {
                    TextEditor(text: $model.text)
                        .focused($focused)
                        .scrollContentBackground(.hidden)
                        .hermesText(.rowTitle)
                        .foregroundStyle(Color(theme.palette.textPrimary))
                        .frame(minHeight: 180)
                        .padding(.horizontal, HermesMetrics.rowInset - 5)
                        .padding(.vertical, 8)
                        .accessibilityIdentifier("importMemoryText")
                        .overlay(alignment: .topLeading) {
                            if model.text.isEmpty {
                                Text("Paste what another assistant remembers about you")
                                    .hermesText(.rowTitle)
                                    .foregroundStyle(Color(theme.palette.sectionCaption))
                                    .padding(.horizontal, HermesMetrics.rowInset)
                                    .padding(.vertical, 16)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                }
                CardFootnote(
                    model.result ?? "One fact per line. Hermes removes repeats and skips anything unsafe.",
                    accessibilityIdentifier: "importMemoryFootnote"
                )
            }
            PillButton(
                "Import", kind: model.canImport ? .accent : .dimmed, size: .large, isBusy: model.isBusy,
                accessibilityIdentifier: "importMemoryButton"
            ) {
                focused = false
                Task { await model.run(api: hub.api) }
            }
            .frame(maxWidth: .infinity)
        }
        .alert("Import Memory", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.failure ?? "")
        }
    }
}

@MainActor
@Observable
final class BotNotificationsModel {
    private(set) var flags: [String: Bool] = [:]
    private(set) var isLoaded = false
    var failure: String?

    func load(bots: [BotRow], api: SettingsAPI) async {
        var loaded: [String: Bool] = [:]
        await withTaskGroup(of: (String, Bool?).self) { group in
            for bot in bots {
                group.addTask { (bot.name, try? await api.notificationsEnabled(bot: bot.name)) }
            }
            for await (name, flag) in group { loaded[name] = flag }
        }
        flags = loaded.compactMapValues { $0 }
        isLoaded = true
    }

    func set(_ enabled: Bool, bot: BotRow, api: SettingsAPI) async {
        let previous = flags[bot.name]
        flags[bot.name] = enabled
        do {
            try await api.setNotifications(enabled, bot: bot.name)
        } catch {
            flags[bot.name] = previous
            failure = SettingsFailure(error).message
        }
    }
}

struct BotNotificationsScreen: View {
    let hub: SettingsHub
    let back: () -> Void

    @State private var model = BotNotificationsModel()

    var body: some View {
        SettingsPage(title: "Notifications by Bot", identifier: "botNotificationsScreen", back: back) {
            if !model.isLoaded {
                GroupedCard(accessibilityIdentifier: "botNotificationsLoading") {
                    LoadingRow(title: "Bots", identifier: "botNotificationsLoadingRow")
                }
            } else if hub.roster.bots.isEmpty {
                GroupedCard(accessibilityIdentifier: "botNotificationsEmpty") {
                    PlaceholderRow("No Bots yet", accessibilityIdentifier: "botNotificationsEmptyRow")
                }
            } else {
                GroupedCard(accessibilityIdentifier: "botNotificationsCard") {
                    ForEach(hub.roster.bots) { bot in
                        SettingsRow.toggle(
                            bot.displayName,
                            isOn: Binding(
                                get: { model.flags[bot.name] ?? true },
                                set: { enabled in Task { await model.set(enabled, bot: bot, api: hub.api) } }
                            ),
                            accessibilityIdentifier: "botNotifications-\(bot.name)"
                        )
                    }
                }
            }
        }
        .task { await model.load(bots: hub.roster.bots, api: hub.api) }
        .alert("Notifications", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.failure ?? "")
        }
    }
}
