#if os(macOS)
import PalDesign
import PalSettings
import SwiftUI

enum MacSettingsSection: String, CaseIterable, Identifiable {
    case general
    case computer
    case permissions
    case vault
    case shortcuts
    case usage
    case updates

    var id: Self { self }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .computer: String(localized: "Computer")
        case .permissions: String(localized: "Permissions")
        case .vault: String(localized: "Vault")
        case .shortcuts: String(localized: "Keyboard Shortcuts")
        case .usage: String(localized: "Usage & Billing")
        case .updates: String(localized: "Updates")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .computer: "display"
        case .permissions: "shield"
        case .vault: "circle.square"
        case .shortcuts: "keyboard"
        case .usage: "chart.bar"
        case .updates: "icloud.and.arrow.down"
        }
    }
}

struct MacSettingsModal: View {
    let hub: SettingsHub
    let connection: ConnectionModel
    @Binding var section: MacSettingsSection

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            PalHairline(axis: .vertical)
            Group {
                switch section {
                case .general: MacGeneralSection(hub: hub, connection: connection)
                case .computer: MacComputerSection(hub: hub, connection: connection)
                case .permissions: MacPermissionsSection(hub: hub)
                case .vault: MacVaultSection(hub: hub)
                case .shortcuts: MacShortcutSettingsSection()
                case .usage: MacUsageSection(hub: hub)
                case .updates: MacUpdatesSection()
                }
            }
            .id(section)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settingsSheet")
    }

    private var sidebar: some View {
        VStack(spacing: 1) {
            ForEach(MacSettingsSection.allCases) { item in
                Button { section = item } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 12))
                            .frame(width: 14)
                        Text(item.title).font(.system(size: 12))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(PalTokens.textPrimary)
                    .padding(.leading, 8)
                    .frame(width: 160, height: 30)
                    .background(section == item ? PalTokens.selected : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(section == item ? .isSelected : [])
                .accessibilityIdentifier("macSettingsSection-\(item.rawValue)")
            }
            Spacer()
        }
        .padding(.top, 15)
        .padding(.leading, 11)
        .frame(width: 181, alignment: .leading)
    }
}

struct MacSectionPage<Accessory: View, Content: View>: View {
    let section: MacSettingsSection
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(section.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(PalTokens.textPrimary)
                    .frame(height: 22)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("macSettingsTitle")
                Spacer()
                accessory
            }
            .padding(.leading, 37)
            .padding(.trailing, 51)
            .padding(.top, 29)
            .frame(height: 57, alignment: .top)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) { content }
                    .padding(.leading, 29)
                    .padding(.trailing, 30)
                    .padding(.top, 20)
                    .padding(.bottom, 28)
            }
            .scrollIndicators(.never)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("macSettingsPage-\(section.rawValue)")
    }
}

extension MacSectionPage where Accessory == EmptyView {
    init(section: MacSettingsSection, @ViewBuilder content: () -> Content) {
        self.init(section: section, accessory: { EmptyView() }, content: content)
    }
}

private struct MacGroup<Content: View>: View {
    var title: LocalizedStringKey?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title { MacCaption(title) }
            content
        }
    }
}

private struct MacLoading: View {
    var body: some View {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 24)
    }
}

private struct MacFailure: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        MacCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(message).font(.system(size: 12)).foregroundStyle(PalTokens.textSecondary)
                Button("Try Again", action: retry).buttonStyle(.palPill(height: 24, fontSize: 11))
            }
            .padding(13)
        }
    }
}

private struct MacEmptyRow: View {
    let text: LocalizedStringKey
    let identifier: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(PalTokens.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .accessibilityIdentifier(identifier)
    }
}

private struct MacGeneralSection: View {
    let hub: SettingsHub
    let connection: ConnectionModel

    @Environment(AppearanceStore.self) private var appearance
    @Environment(\.openURL) private var openURL
    @State private var notifications = SystemNotifications()
    @State private var sharing = DataSharingModel()
    @State private var confirmingSignOut = false
    @State private var confirmingAdd = false

    private static let themes: [AppearanceMode] = [.followSystem, .light, .dark, .black]
    private static let zones = TimeZone.knownTimeZoneIdentifiers.sorted()
    private static let languageSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")

    private var themeSelection: Binding<AppearanceMode> {
        Binding(
            get: { appearance.mode == .botColor ? .dark : appearance.mode },
            set: { appearance.mode = $0 }
        )
    }

    private var accentIsBotColor: Binding<Bool> {
        Binding(
            get: { appearance.mode == .botColor },
            set: { useBotColor in
                if useBotColor { appearance.mode = .botColor } else if appearance.mode == .botColor { appearance.mode = .dark }
            }
        )
    }

    private var zoneSelection: Binding<String> {
        Binding(
            get: { hub.timeZoneDisplay },
            set: { identifier in Task { await hub.setTimeZone(identifier) } }
        )
    }

    private var accountName: String { connection.userName.isEmpty ? String(localized: "Account") : connection.userName }

    var body: some View {
        MacSectionPage(section: .general) {
            accountCard
            appearanceCard
            systemCard
            botCard
            privacyCard
        }
        .task { await notifications.refresh() }
        .task { await sharing.load(api: hub.api) }
        .confirmationDialog("Sign out of Pal on this device?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await connection.signOut() } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Signing in with another account replaces this one on this device.",
            isPresented: $confirmingAdd, titleVisibility: .visible
        ) {
            Button("Continue", role: .destructive) { Task { await connection.signOut() } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Settings", isPresented: Binding(get: { hub.message != nil }, set: { if !$0 { hub.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(hub.message ?? "")
        }
    }

    private var accountCard: some View {
        MacGroup(title: "Account") {
            MacCard(identifier: "settingsAccountCard") {
                HStack(spacing: 12) {
                    InitialAvatar(initial: connection.userInitial, diameter: 40)
                    HStack(spacing: 6) {
                        Text(accountName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(PalTokens.textPrimary)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text(verbatim: accountName))
                            .accessibilityIdentifier("settingsAccountRow")
                        if !connection.userName.isEmpty {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(connection.userName, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10))
                                    .foregroundStyle(PalTokens.textSecondary)
                                    .frame(width: 18, height: 18)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(String(localized: "Copy"))
                            .accessibilityLabel(Text("Copy account name"))
                            .accessibilityIdentifier("settingsAccountCopy")
                        }
                    }
                    Spacer()
                    GlassEffectContainer(spacing: 6) {
                        HStack(spacing: 6) {
                            Button("Add account") { confirmingAdd = true }
                                .buttonStyle(.palPill)
                                .accessibilityIdentifier("accountAddRow")
                            Button("Sign Out") { confirmingSignOut = true }
                                .buttonStyle(.palPill)
                                .accessibilityIdentifier("settingsSignOutRow")
                        }
                    }
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 14)
            }
        }
    }

    private var appearanceCard: some View {
        MacGroup(title: "Appearance") {
            MacCard(identifier: "settingsAppearanceCard") {
                MacRow(title: String(localized: "Theme"), identifier: "settingsAppearanceRow") {
                    MacMenuValue(current: themeSelection.wrappedValue.title, selection: themeSelection, identifier: "macThemeMenu") {
                        ForEach(Self.themes) { mode in Text(mode.title).tag(mode) }
                    }
                }
                MacRow(title: String(localized: "Accent"), identifier: "macAccentRow") {
                    MacMenuValue(
                        current: accentIsBotColor.wrappedValue ? String(localized: "Bot color") : String(localized: "Default"),
                        selection: accentIsBotColor, identifier: "macAccentMenu"
                    ) {
                        Text("Default").tag(false)
                        Text("Bot color").tag(true)
                    }
                }
                Button {
                    if let url = Self.languageSettingsURL { openURL(url) }
                } label: {
                    MacRow(title: String(localized: "Language"), identifier: "settingsLanguageRow") {
                        MacValueLabel(text: String(localized: "Follow System"))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var systemCard: some View {
        MacGroup(title: "System") {
            MacCard(identifier: "settingsPreferencesCard") {
                MacRow(title: String(localized: "Notifications"), subtitle: String(localized: "Get notified when a Bot finishes"), identifier: "settingsNotificationsRow") {
                    Toggle("Notifications", isOn: Binding(
                        get: { notifications.isOn },
                        set: { enabled in Task { await notifications.set(enabled, hub: hub, openSettings: openSystemSettings) } }
                    ))
                    .labelsHidden()
                    .toggleStyle(.macSwitch)
                    .accessibilityIdentifier("settingsNotificationsToggle")
                }
            }
        }
    }

    private var botCard: some View {
        MacGroup(title: "Bot") {
            MacCard(identifier: "settingsBotCard") {
                MacRow(
                    title: SettingsCopy.timeZoneAutoTitle, subtitle: SettingsCopy.timeZoneAutoSubtitle,
                    identifier: "settingsTimeZoneAutoRow"
                ) {
                    Toggle(SettingsCopy.timeZoneAutoTitle, isOn: Binding(
                        get: { hub.timeZoneIsAutomatic },
                        set: { enabled in Task { await hub.setTimeZoneAutomatic(enabled) } }
                    ))
                    .labelsHidden()
                    .toggleStyle(.macSwitch)
                    .accessibilityIdentifier("settingsTimeZoneAutoToggle")
                }
                MacRow(title: String(localized: "Time Zone"), identifier: "settingsTimeZoneRow") {
                    if hub.timeZoneIsAutomatic {
                        Text(TimeZoneNames.display(hub.timeZoneDisplay))
                            .font(.system(size: 11.5))
                            .foregroundStyle(PalTokens.textSecondary)
                    } else {
                        MacMenuValue(current: TimeZoneNames.display(hub.timeZoneDisplay), selection: zoneSelection, identifier: "macTimeZoneMenu") {
                            ForEach(Self.zones, id: \.self) { Text(TimeZoneNames.display($0)).tag($0) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var privacyCard: some View {
        if case .loaded(let metrics) = sharing.state {
            MacGroup(title: "Data sharing") {
                MacCard(identifier: "dataSharingCard") {
                    MacRow(title: String(localized: "Share usage data"), subtitle: String(localized: "Help improve Hermes with anonymous usage information."), identifier: "dataSharingEnabledRow") {
                        Toggle("Share usage data", isOn: Binding(
                            get: { metrics.enabled },
                            set: { value in Task { await sharing.set(enabled: value, send: metrics.send, api: hub.api) } }
                        ))
                        .labelsHidden()
                        .toggleStyle(.macSwitch)
                        .accessibilityIdentifier("dataSharingEnabledToggle")
                    }
                    MacRow(title: String(localized: "Send reports automatically"), subtitle: String(localized: "Upload the shared usage data to Hermes."), identifier: "dataSharingSendRow") {
                        Toggle("Send reports automatically", isOn: Binding(
                            get: { metrics.enabled && metrics.send },
                            set: { value in Task { await sharing.set(enabled: metrics.enabled, send: value, api: hub.api) } }
                        ))
                        .labelsHidden()
                        .toggleStyle(.macSwitch)
                        .disabled(!metrics.enabled)
                        .accessibilityIdentifier("dataSharingSendToggle")
                    }
                }
                MacFootnote(text: String(localized: "Your conversations are never part of this data."))
            }
        }
    }

    private func openSystemSettings() {
        if let url = SystemSettings.notificationSettingsURL { openURL(url) }
    }
}

private struct MacComputerSection: View {
    let hub: SettingsHub
    let connection: ConnectionModel

    @State private var computer = BotComputerSettingsModel()
    @State private var devices = DevicesModel()
    @State private var confirmingReset = false
    @State private var removing: DeviceEntry?

    var body: some View {
        MacSectionPage(section: .computer) {
            devicesCard
            computerCard
        }
        .task { await computer.load(api: hub.api) }
        .task { await devices.load(api: hub.api, localDeviceID: connection.localDeviceID) }
        .confirmationDialog("Reset Computer?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset Computer", role: .destructive) { Task { await computer.reset(api: hub.api) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rebuild from your last saved snapshot. Very recent changes may be lost.")
        }
        .confirmationDialog(
            removing.map { "Remove \($0.name)?" } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let device = removing {
                    Task { _ = await devices.forget(device, api: hub.api, localDeviceID: connection.localDeviceID) }
                }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("It will be signed out and will stop receiving notifications.")
        }
        .alert("Computer", isPresented: Binding(
            get: { computer.failure != nil || devices.failure != nil },
            set: { if !$0 { computer.failure = nil; devices.failure = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(computer.failure ?? devices.failure ?? "")
        }
    }

    private var diskText: String {
        switch computer.state {
        case .loading: " "
        case .loaded(let summary): summary.disk.text
        case .failed: String(localized: "Unavailable")
        }
    }

    private var computerCard: some View {
        MacGroup(title: "Bot's computer") {
            MacCard(identifier: "botComputerResetCard") {
                MacRow(title: String(localized: "Disk space"), identifier: "botComputerDisk") {
                    Text(diskText).font(.system(size: 11.5)).foregroundStyle(PalTokens.textSecondary)
                }
                MacRow(
                    title: String(localized: "Reset Computer"),
                    subtitle: String(localized: "Rebuild from your last saved snapshot. Very recent changes may be lost."),
                    identifier: "botComputerResetRow"
                ) {
                    Button("Reset") { confirmingReset = true }
                        .buttonStyle(.palPill)
                        .disabled(computer.isResetting)
                        .accessibilityIdentifier("botComputerResetButton")
                }
            }
            MacFootnote(text: computer.notice ?? String(localized: "The one computer your Bots share."), identifier: "botComputerFootnote")
        }
    }

    @ViewBuilder
    private var devicesCard: some View {
        MacGroup(title: "Manage devices") {
            switch devices.state {
            case .loading:
                MacCard { MacLoading() }
            case .failed(let message):
                MacFailure(message: message) { Task { await devices.load(api: hub.api, localDeviceID: connection.localDeviceID) } }
            case .loaded(let entries):
                MacCard(identifier: "devicesCard") {
                    ForEach(entries) { deviceRow($0) }
                }
            }
        }
    }

    private func deviceRow(_ device: DeviceEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: device.symbolName)
                .font(.system(size: 12, weight: .light))
                .foregroundStyle(PalTokens.textSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.system(size: 12, weight: .medium)).foregroundStyle(PalTokens.textPrimary)
                HStack(spacing: 5) {
                    StatusDot(isOn: device.isOnline)
                    Text(device.subtitle(now: Date())).font(.system(size: 11)).foregroundStyle(PalTokens.textSecondary)
                }
            }
            Spacer()
            if !device.isThisDevice {
                Button("Remove") { removing = device }
                    .buttonStyle(.palPill(height: 24, fontSize: 11))
                    .accessibilityIdentifier("deviceRemove-\(device.id)")
            }
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 53)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("device-\(device.id)")
    }
}

private struct MacPermissionsSection: View {
    let hub: SettingsHub

    @State private var model = PermissionsModel()
    @State private var addingTo: PermissionList?
    @State private var removing: PermissionRuleEntry?

    var body: some View {
        MacSectionPage(section: .permissions) {
            switch model.state {
            case .loading: MacCard { MacLoading() }
            case .failed(let message): MacFailure(message: message) { Task { await model.load(hub: hub) } }
            case .loaded(let summary): content(summary)
            }
        }
        .task { await model.load(hub: hub) }
        .sheet(item: $addingTo) { list in
            AddRuleSheet(list: list, model: model, hub: hub) { addingTo = nil }
                .macSheetFrame()
        }
        .confirmationDialog(
            "Remove this rule?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let rule = removing { Task { await model.remove(rule, hub: hub) } }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text(removing?.text ?? "")
        }
        .alert("Permissions", isPresented: Binding(get: { model.actionFailure != nil }, set: { if !$0 { model.actionFailure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionFailure ?? "")
        }
    }

    @ViewBuilder
    private func content(_ summary: PermissionsSummary) -> some View {
        MacGroup {
            MacCard(identifier: "permissionsAutoReviewCard") {
                MacRow(
                    title: String(localized: "Auto-Review"), subtitle: String(localized: "Review your Bots' actions based on custom rules"),
                    identifier: "permissionsAutoReviewRow"
                ) {
                    Toggle("Auto-Review", isOn: Binding(
                        get: { summary.autoReview },
                        set: { enabled in Task { await model.setAutoReview(enabled, hub: hub) } }
                    ))
                    .labelsHidden()
                    .toggleStyle(.macSwitch)
                    .accessibilityIdentifier("permissionsAutoReviewToggle")
                }
            }
            if summary.approvalsAreOff {
                MacFootnote(text: String(localized: "Approvals are turned off for this Bot, so rules are saved but not applied."), identifier: "permissionsApprovalsOff")
            }
        }
        VStack(alignment: .leading, spacing: 16) {
            ruleSection(.ask, title: String(localized: "Always Ask"), subtitle: String(localized: "Stop and ask when an action matches these rules"), rules: summary.ask)
            ruleSection(.allow, title: String(localized: "Allow without Asking"), subtitle: String(localized: "Continue automatically when an action matches these rules"), rules: summary.allow)
        }
    }

    private func ruleSection(_ list: PermissionList, title: String, subtitle: String, rules: [PermissionRuleEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 11.5)).foregroundStyle(PalTokens.textTertiary)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(PalTokens.textTertiary)
                }
                Spacer()
                Button("Add Rule") { addingTo = list }
                    .buttonStyle(.palPill(height: 24, fontSize: 11))
                    .accessibilityIdentifier("permissionsAddRule-\(list.rawValue)")
            }
            .padding(.horizontal, 13)
            if !rules.isEmpty {
                MacCard(identifier: "permissionsRules-\(list.rawValue)") {
                    ForEach(rules) { rule in
                        MacRow(title: rule.text, identifier: "permissionsRule-\(rule.id)") {
                            Button("Remove") { removing = rule }
                                .buttonStyle(.palPill(height: 24, fontSize: 11))
                                .accessibilityIdentifier("permissionsRemove-\(rule.id)")
                        }
                    }
                }
            }
        }
    }
}

private enum MacVaultFilter: String, CaseIterable, Identifiable {
    case all
    case logins
    case payments
    case contact

    var id: Self { self }

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .logins: String(localized: "Logins")
        case .payments: String(localized: "Payments")
        case .contact: String(localized: "Contact info")
        }
    }

    func includes(_ entry: VaultEntry) -> Bool {
        switch self {
        case .all: true
        case .logins: entry.kind == .login
        case .payments: entry.kind == .payment
        case .contact: entry.kind == .address
        }
    }
}

private struct MacVaultSection: View {
    let hub: SettingsHub

    @State private var model = VaultModel()
    @State private var filter = MacVaultFilter.all
    @State private var query = ""
    @State private var adding = false
    @State private var removing: VaultEntry?

    var body: some View {
        MacSectionPage(
            section: .vault,
            accessory: {
                Button("New item") { adding = true }
                    .buttonStyle(.palPill(height: 28, fontSize: 12, horizontalPadding: 14, fill: PalTokens.inverseFill, textColor: PalTokens.inverseText))
                    .accessibilityIdentifier("vaultAddButton")
            },
            content: {
                switch model.state {
                case .loading: MacCard { MacLoading() }
                case .failed(let message): MacFailure(message: message) { Task { await model.load(api: hub.api) } }
                case .loaded(let entries): loaded(entries)
                }
            }
        )
        .task { await model.load(api: hub.api) }
        .sheet(isPresented: $adding) {
            AddVaultLoginSheet(model: model, hub: hub) { adding = false }
                .macSheetFrame()
        }
        .confirmationDialog(
            "Remove this item from your vault?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let entry = removing { Task { await model.remove(entry, api: hub.api) } }
                removing = nil
            }
            .accessibilityIdentifier("vaultRemoveConfirm")
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text(removing?.title ?? "")
        }
        .alert("Vault", isPresented: Binding(get: { model.actionFailure != nil }, set: { if !$0 { model.actionFailure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionFailure ?? "")
        }
    }

    private func visible(_ entries: [VaultEntry]) -> [VaultEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            filter.includes(entry)
                && (needle.isEmpty || entry.title.localizedStandardContains(needle) || (entry.subtitle?.localizedStandardContains(needle) ?? false))
        }
    }

    @ViewBuilder
    private func loaded(_ entries: [VaultEntry]) -> some View {
        HStack(spacing: 4) {
            ForEach(MacVaultFilter.allCases) { item in tab(item, count: entries.filter(item.includes).count) }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(PalTokens.textSecondary)
                TextField("Search Vault", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .accessibilityIdentifier("vaultSearchField")
            }
            .padding(.horizontal, 12)
            .frame(width: 165, height: 28)
            .palGlass(Capsule(), interactive: false)
        }
        .padding(.top, 6)
        let shown = visible(entries)
        VStack(alignment: .leading, spacing: 0) {
            MacCard(identifier: "vaultCard") {
                if shown.isEmpty {
                    MacEmptyRow(text: entries.isEmpty ? "Your vault is empty" : "No matching items", identifier: "vaultEmptyRow")
                } else {
                    ForEach(shown) { row($0) }
                }
            }
            MacFootnote(text: String(localized: "Passwords are stored encrypted on your Hermes computer. Your Bots can use them but never read them."), identifier: "vaultFootnote")
        }
    }

    private func tab(_ item: MacVaultFilter, count: Int) -> some View {
        let selected = filter == item
        return Button { filter = item } label: {
            HStack(spacing: 4) {
                Text(item.title)
                Text("\(count)").foregroundStyle(PalTokens.textTertiary)
            }
            .font(.system(size: 12))
            .foregroundStyle(selected ? PalTokens.textPrimary : PalTokens.textSecondary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(selected ? PalTokens.selected : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(item.title) \(count)"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("macVaultTab-\(item.rawValue)")
    }

    private func row(_ entry: VaultEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.kind.symbolName)
                .font(.system(size: 11))
                .foregroundStyle(PalTokens.textSecondary)
                .frame(width: 24, height: 24)
                .background(PalTokens.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.system(size: 12, weight: .medium)).foregroundStyle(PalTokens.textPrimary).lineLimit(1)
                if let subtitle = entry.subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(PalTokens.textSecondary).lineLimit(1)
                }
            }
            Spacer()
            if entry.isRemovable {
                Button("Remove") { removing = entry }
                    .buttonStyle(.palPill(height: 24, fontSize: 11))
                    .accessibilityIdentifier("vaultRemove-\(entry.id)")
            }
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 46)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vaultItem-\(entry.id)")
    }
}

private struct MacUsageSection: View {
    let hub: SettingsHub

    @State private var model = UsageModel()

    var body: some View {
        MacSectionPage(
            section: .usage,
            accessory: {
                Button("Refresh") { Task { await model.refresh(api: hub.api) } }
                    .buttonStyle(.palPill(height: 28))
                    .disabled(model.isRefreshing)
                    .accessibilityIdentifier("usageRefreshButton")
            },
            content: {
                switch model.state {
                case .loading:
                    MacCard { MacLoading() }
                case .failed(let message):
                    MacFailure(message: message) { Task { await model.refresh(api: hub.api) } }
                case .loaded(let overview):
                    if overview.accounts.isEmpty {
                        MacCard(identifier: "usageEmpty") { MacEmptyRow(text: "No accounts connected yet", identifier: "usageEmptyRow") }
                    } else {
                        ForEach(overview.accounts) { MacUsageAccount(account: $0) }
                    }
                    if let failure = model.refreshFailure { MacFootnote(text: failure, identifier: "usageRefreshFailure") }
                }
            }
        )
        .task { await model.load(api: hub.api) }
    }
}

private struct MacUsageAccount: View {
    let account: UsageAccount

    private var caption: String {
        var parts = [account.title]
        if let label = account.accountLabel { parts.append(label) }
        if account.standing == .limited { parts.append(String(localized: "Limit reached")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        TimelineView(.everyMinute) { timeline in
            VStack(alignment: .leading, spacing: 0) {
                MacCaption(verbatim: caption).accessibilityIdentifier("usageCaption-\(account.id)")
                VStack(spacing: 12) {
                    ForEach(account.meters) { meter in
                        MacMeterCard(meter: meter, resetText: meter.resetText(now: timeline.date))
                    }
                    if account.hasNoLimits || account.spend != nil || account.note != nil || account.meters.isEmpty {
                        MacCard(identifier: "usageCard-\(account.id)") {
                            if account.hasNoLimits {
                                MacRow(title: String(localized: "No usage limits"), subtitle: String(localized: "This account is billed by usage."), identifier: "usageNoLimits-\(account.id)") { EmptyView() }
                            }
                            if let spend = account.spend {
                                MacRow(title: spend.title, subtitle: spend.detailText, identifier: "usageSpend-\(account.id)") {
                                    Text(spend.valueText()).font(.system(size: 11.5)).foregroundStyle(PalTokens.textSecondary)
                                }
                            }
                            if let note = account.note {
                                MacRow(title: note, identifier: "usageNote-\(account.id)") { EmptyView() }
                            }
                            if account.meters.isEmpty, account.spend == nil, account.note == nil, !account.hasNoLimits {
                                MacRow(title: String(localized: "Usage is not available yet."), identifier: "usageNone-\(account.id)") { EmptyView() }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct MacMeterCard: View {
    let meter: UsageMeter
    let resetText: String?

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        MacCard {
            VStack(alignment: .leading, spacing: 0) {
                Text(meter.title).font(.system(size: 12)).foregroundStyle(PalTokens.textPrimary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(meter.percentText).font(.system(size: 20)).foregroundStyle(PalTokens.textPrimary)
                    Text("used").font(.system(size: 11)).foregroundStyle(PalTokens.textSecondary)
                }
                .padding(.top, 10)
                Capsule()
                    .fill(PalTokens.control)
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(meter.isExhausted ? Color(theme.palette.destructive) : PalTokens.toggleOn)
                                .frame(width: max(4, proxy.size.width * min(1, max(0, meter.fraction))))
                        }
                    }
                    .padding(.top, 10)
                if let resetText {
                    Text(resetText).font(.system(size: 11)).foregroundStyle(PalTokens.textSecondary).padding(.top, 8)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("usageMeter-\(meter.id)")
        }
    }
}

private struct MacUpdatesSection: View {
    var body: some View {
        MacSectionPage(section: .updates) {
            MacGroup(title: "Pal Updates") {
                MacCard(identifier: "updatesCard") {
                    MacRow(
                        title: String(localized: "Version \(AppVersion.display)"),
                        subtitle: String(localized: "Automatic updates for the Mac app are not available yet."),
                        identifier: "updatesVersionRow"
                    ) {
                        Button("Check for Updates") {}
                            .buttonStyle(.palPill)
                            .disabled(true)
                            .accessibilityIdentifier("updatesCheckButton")
                    }
                }
            }
        }
    }
}
#endif
