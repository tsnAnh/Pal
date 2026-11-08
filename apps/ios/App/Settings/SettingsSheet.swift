import HermesDesign
import HermesSettings
import SwiftUI

enum SettingsCopy {
    static let vaultSubtitle = "Logins, cards and contact info your Bots can use"
    static let timeZoneAutoTitle = "Set Time Zone Automatically"
    static let timeZoneAutoSubtitle = "Your Bot's computer follows this device's time zone."
}

struct SettingsSheet: View {
    @Bindable var model: ConnectionModel
    let roster: RosterModel
    let onClose: () -> Void

    @State private var hub: SettingsHub
    @State private var path: [SettingsRoute] = []

    init(model: ConnectionModel, roster: RosterModel, onClose: @escaping () -> Void) {
        self.model = model
        self.roster = roster
        self.onClose = onClose
        _hub = State(initialValue: SettingsHub(connection: model, roster: roster))
    }

    var body: some View {
        NavigationStack(path: $path) {
            SettingsRootView(hub: hub, connection: model, onClose: onClose) { path.append($0) }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: SettingsRoute.self) { route in
                    SettingsDestination(route: route, hub: hub, connection: model) { path.removeLast() }
                        .toolbar(.hidden, for: .navigationBar)
                }
        }
        .task { await hub.refresh() }
    }
}

private struct SettingsDestination: View {
    let route: SettingsRoute
    let hub: SettingsHub
    let connection: ConnectionModel
    let back: () -> Void

    var body: some View {
        switch route {
        case .account: AccountScreen(connection: connection, back: back)
        case .usage: UsageScreen(hub: hub, back: back)
        case .vault: VaultScreen(hub: hub, back: back)
        case .permissions: PermissionsScreen(hub: hub, back: back)
        case .timeZone: TimeZoneScreen(hub: hub, back: back)
        case .botComputer: BotComputerScreen(hub: hub, back: back)
        case .devices: DevicesScreen(hub: hub, connection: connection, back: back)
        case .importMemory: ImportMemoryScreen(hub: hub, back: back)
        case .botNotifications: BotNotificationsScreen(hub: hub, back: back)
        case .appearance: AppearanceScreen(back: back)
        case .haptics: HapticsScreen(back: back)
        case .dataSharing: DataSharingScreen(hub: hub, back: back)
        }
    }
}

struct SettingsRootView: View {
    let hub: SettingsHub
    let connection: ConnectionModel
    let onClose: () -> Void
    let open: (SettingsRoute) -> Void

    @Environment(AppearanceStore.self) private var appearance
    @Environment(\.openURL) private var openURL
    @AppStorage(SettingsDefaults.hapticsKey) private var hapticsEnabled = true
    @State private var notifications = SystemNotifications()
    @State private var confirmingSignOut = false
    @State private var sharingFeedback = false

    var body: some View {
        SheetChrome(accessibilityIdentifier: "settingsSheet", onLeading: onClose) {
            ScrollView {
                VStack(spacing: HermesMetrics.cardGap) {
                    accountCard
                    botCard
                    preferencesCard
                    feedbackCard
                    signOutCard
                    BrandMarkFooter(name: "Hermes Bots", version: AppVersion.display)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                }
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("settingsScroll")
        }
        .task { await notifications.refresh() }
        .sheet(isPresented: $sharingFeedback) {
            ShareSheet(items: [FeedbackReport.text(connection: connection)])
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog("Sign out of Hermes Bots on this device?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await connection.signOut() } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Settings", isPresented: Binding(get: { hub.message != nil }, set: { if !$0 { hub.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(hub.message ?? "")
        }
    }

    private var accountCard: some View {
        GroupedCard(accessibilityIdentifier: "settingsAccountCard") {
            LeadingSettingsRow(
                title: connection.userName.isEmpty ? "Account" : connection.userName,
                subtitle: connection.gatewayHost,
                trailing: .chevron,
                accessibilityIdentifier: "settingsAccountRow",
                action: { open(.account) }
            ) {
                InitialAvatar(initial: connection.userInitial)
            }
            .frame(minHeight: 70)
            SettingsRow.navigate(
                "Usage", value: hub.usageHeadline, accessibilityIdentifier: "settingsUsageRow", action: { open(.usage) }
            )
            SettingsRow.navigate(
                "Vault", subtitle: SettingsCopy.vaultSubtitle, accessibilityIdentifier: "settingsVaultRow", action: { open(.vault) }
            )
        }
    }

    private var botCard: some View {
        VStack(alignment: .leading, spacing: HermesMetrics.captionToCardGap) {
            SectionCaption("Bot", accessibilityIdentifier: "settingsBotCaption")
            GroupedCard(accessibilityIdentifier: "settingsBotCard") {
                SettingsRow.navigate(
                    "Permissions", subtitle: hub.permissions?.rowSubtitle ?? " ",
                    accessibilityIdentifier: "settingsPermissionsRow", action: { open(.permissions) }
                )
                SettingsRow.toggle(
                    SettingsCopy.timeZoneAutoTitle, subtitle: SettingsCopy.timeZoneAutoSubtitle,
                    isOn: Binding(
                        get: { hub.timeZoneIsAutomatic },
                        set: { enabled in Task { await hub.setTimeZoneAutomatic(enabled) } }
                    ),
                    accessibilityIdentifier: "settingsTimeZoneAutoToggle"
                )
                timeZoneRow
                SettingsRow.navigate("Bot Computer", accessibilityIdentifier: "settingsBotComputerRow", action: { open(.botComputer) })
                SettingsRow.navigate("Manage your devices", accessibilityIdentifier: "settingsDevicesRow", action: { open(.devices) })
                SettingsRow.navigate("Import Memory", accessibilityIdentifier: "settingsImportMemoryRow", action: { open(.importMemory) })
            }
        }
    }

    @ViewBuilder
    private var timeZoneRow: some View {
        if hub.timeZoneIsAutomatic {
            SettingsRow.value("Time Zone", value: TimeZoneNames.display(hub.timeZoneDisplay), accessibilityIdentifier: "settingsTimeZoneRow")
        } else {
            SettingsRow(
                title: "Time Zone", value: TimeZoneNames.display(hub.timeZoneDisplay), trailing: .none,
                accessibilityIdentifier: "settingsTimeZoneRow", action: { open(.timeZone) }
            )
        }
    }

    private var preferencesCard: some View {
        GroupedCard(accessibilityIdentifier: "settingsPreferencesCard") {
            SettingsRow.toggle(
                "Notifications",
                isOn: Binding(
                    get: { notifications.isOn },
                    set: { enabled in Task { await notifications.set(enabled, hub: hub, openSettings: openSystemSettings) } }
                ),
                accessibilityIdentifier: "settingsNotificationsToggle"
            )
            if notifications.isOn {
                SettingsRow.navigate(
                    "Notifications by Bot", subtitle: "Choose which Bots can notify you",
                    accessibilityIdentifier: "settingsBotNotificationsRow", action: { open(.botNotifications) }
                )
            }
            SettingsRow.navigate(
                "Appearance", value: appearance.mode.title, accessibilityIdentifier: "settingsAppearanceRow", action: { open(.appearance) }
            )
            SettingsRow.navigate(
                "Language", value: LanguageName.current, accessibilityIdentifier: "settingsLanguageRow", action: openSystemSettings
            )
            SettingsRow.navigate(
                "Haptics", value: hapticsEnabled ? "On" : "Off", accessibilityIdentifier: "settingsHapticsRow", action: { open(.haptics) }
            )
            SettingsRow.navigate("Data sharing", accessibilityIdentifier: "settingsDataSharingRow", action: { open(.dataSharing) })
        }
    }

    private var feedbackCard: some View {
        GroupedCard(accessibilityIdentifier: "settingsFeedbackCard") {
            SettingsRow.navigate("Send Feedback", accessibilityIdentifier: "settingsFeedbackRow", action: { sharingFeedback = true })
        }
    }

    private var signOutCard: some View {
        GroupedCard(accessibilityIdentifier: "settingsSignOutCard") {
            SettingsRow.destructive("Sign Out", accessibilityIdentifier: "settingsSignOutRow", action: { confirmingSignOut = true })
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}
