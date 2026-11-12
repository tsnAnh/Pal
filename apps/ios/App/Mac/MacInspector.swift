#if os(macOS)
import PalBotProfile
import PalConnect
import PalDesign
import SwiftUI

private enum InspectorTab: String, CaseIterable, Identifiable {
    case activity
    case library

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .activity: "Activity"
        case .library: "Library"
        }
    }
}

struct MacInspector: View {
    let botName: String
    let roster: RosterModel
    let router: AppRouter

    @State private var profile: BotProfileModel
    @State private var routines: RoutinesModel
    @State private var library: LibraryModel
    @State private var suggestions: ConnectedServicesModel
    @State private var tab = InspectorTab.activity
    @State private var creation: NewRoutineModel?
    @AppStorage("mac.inspector.suggestionsHidden") private var suggestionsHidden = false

    @Environment(MacShell.self) private var shell
    @Environment(ActionAutoApprove.self) private var autoApprove

    init(botName: String, roster: RosterModel, router: AppRouter, bots: BotsKit) {
        self.botName = botName
        self.roster = roster
        self.router = router
        _profile = State(initialValue: BotProfileModel(botName: botName, services: bots.services, roster: roster, sharer: bots.sharer))
        _routines = State(initialValue: RoutinesModel(botName: botName, services: bots.services))
        _library = State(initialValue: LibraryModel(botName: botName, services: bots.services))
        _suggestions = State(initialValue: ConnectedServicesModel(botName: botName, services: bots.services))
    }

    var body: some View {
        VStack(spacing: 0) {
            hero
            tabs.padding(.top, 18).padding(.bottom, 8)
            switch tab {
            case .activity:
                ScrollView {
                    activity
                        .padding(.leading, 12)
                        .padding(.trailing, 15)
                        .padding(.bottom, 24)
                }
                .scrollIndicators(.never)
            case .library:
                LibraryView(model: library, showsChrome: false, filters: [.all, .media, .files])
            }
        }
        .overlay(alignment: .topTrailing) { closeButton }
        .background(PalTokens.content)
        .overlay(alignment: .leading) { PalHairline(axis: .vertical) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("botProfileScreen")
        .task { await profile.load() }
        .task { await routines.load() }
        .task { await suggestions.load() }
        .task(id: sessionID) { await autoApprove.load(sessionID: sessionID) }
        .toast($profile.toast)
        .sheet(item: $creation) { created in
            NewRoutineSheet(model: created) { creation = nil }
                .macSheetFrame()
        }
        .sheet(item: Binding(get: { profile.editing }, set: { if $0 == nil { profile.endEditing() } })) { editing in
            EditBotSheet(model: editing) { profile.endEditing() }
                .macSheetFrame()
        }
        .confirmationDialog(
            Text("Replace Primary Bot?"),
            isPresented: $profile.confirmsReplacePrimary,
            titleVisibility: .visible
        ) {
            Button("Replace") { Task { await profile.replacePrimary() } }
                .accessibilityIdentifier("replacePrimaryConfirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(profile.displayName) becomes your primary bot. Nothing is copied or deleted.")
        }
    }

    private var sessionID: String? { profile.row?.conversationID }

    private var closeButton: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 8) {
                Menu {
                    Button("Edit…", systemImage: "square.and.pencil") { profile.beginEditing() }
                        .disabled(profile.profile == nil)
                        .accessibilityIdentifier("profileEditButton")
                    Button("New Routine…", systemImage: "plus") { creation = routines.creationModel() }
                        .accessibilityIdentifier("routinesNewButton")
                    if suggestionsHidden, !suggestions.visibleSuggestions.isEmpty {
                        Button("Show Suggestions", systemImage: "eye") { suggestionsHidden = false }
                            .accessibilityIdentifier("inspectorShowSuggestions")
                    }
                    Divider()
                    if !profile.isPrimary {
                        Button("Replace Primary Bot…", systemImage: "star") { profile.confirmsReplacePrimary = true }
                            .accessibilityIdentifier("profileReplacePrimary")
                    }
                    Button("Copy ID", systemImage: "doc.on.doc") { profile.copyID() }
                        .accessibilityIdentifier("profileCopyID")
                } label: {
                    inspectorGlyph("ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text("More"))
                .accessibilityIdentifier("profileMoreButton")
                Button { shell.showsInspector = false } label: {
                    inspectorGlyph("xmark")
                }
                .buttonStyle(.plain)
                .help(String(localized: "Close details"))
                .accessibilityLabel(Text("Close details"))
                .accessibilityIdentifier("inspectorClose")
            }
        }
        .padding(.top, 12)
        .padding(.trailing, 12)
    }

    private func inspectorGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(PalTokens.textSecondary)
            .frame(width: 32, height: 32)
            .palGlass(Circle())
            .contentShape(Circle())
    }

    private var hero: some View {
        VStack(spacing: 0) {
            AvatarBadge(diameter: 55, showsPrimaryBadge: profile.isPrimary, accessibilityIdentifier: "profileAvatarArtwork") {
                if let spec = profile.spec {
                    BotAvatarView(spec: spec, size: 55 * 1.44)
                } else {
                    Color.clear
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(profile.displayName))
            .accessibilityIdentifier("profileAvatar")
            .padding(.top, 64)
            Text(profile.displayName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(PalTokens.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.top, 21)
                .padding(.horizontal, 24)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("profileName")
        }
        .frame(maxWidth: .infinity)
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(InspectorTab.allCases) { item in
                Button { withAnimation(.snappy(duration: 0.18)) { tab = item } } label: {
                    Text(item.title)
                        .font(.system(size: 12, weight: tab == item ? .medium : .regular))
                        .foregroundStyle(tab == item ? PalTokens.textPrimary : PalTokens.textSecondary)
                        .padding(.horizontal, 11)
                        .frame(height: 24)
                        .background(tab == item ? PalTokens.elevated : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
                .accessibilityIdentifier("inspectorTab-\(item.rawValue)")
            }
        }
    }

    private var activity: some View {
        VStack(spacing: 0) {
            InspectorSection(title: String(localized: "Upcoming"), identifier: "inspectorRoutines", first: true) {
                EmptyView()
            } content: {
                routinesList
            }
            if !suggestionsHidden, !suggestions.visibleSuggestions.isEmpty {
                InspectorSection(title: String(localized: "Suggested"), identifier: "inspectorSuggested") {
                    Button("Hide") { withAnimation(.snappy(duration: 0.18)) { suggestionsHidden = true } }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(PalTokens.textSecondary)
                        .accessibilityIdentifier("inspectorHideSuggested")
                } content: {
                    ForEach(suggestions.visibleSuggestions, id: \.self) { suggestion in
                        switch suggestion {
                        case .addToSlack:
                            InspectorRow(identifier: "profileSlackRow", action: { router.push(.slack(botName: botName)) }) {
                                SlackMark().frame(width: 14, height: 14)
                                Text("Add to Slack").font(.system(size: 12)).foregroundStyle(PalTokens.textPrimary)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(PalTokens.textTertiary)
                            }
                        }
                    }
                }
            }
            InspectorSection(title: String(localized: "Computer"), identifier: "inspectorComputer") {
                EmptyView()
            } content: {
                InspectorRow(identifier: "profileComputerRow", action: { router.push(.computer(botName: botName)) }) {
                    Image(systemName: "display").font(.system(size: 13)).foregroundStyle(PalTokens.textSecondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Bot's computer").font(.system(size: 12)).foregroundStyle(PalTokens.textPrimary)
                        Text(profile.computer?.text ?? " ").font(.system(size: 11)).foregroundStyle(PalTokens.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(PalTokens.textTertiary)
                }
            }
            InspectorSection(title: String(localized: "Model"), identifier: "inspectorModel") {
                EmptyView()
            } content: {
                InspectorRow(identifier: "profileModelRow", action: { router.push(.botModel(botName: botName)) }) {
                    Image(systemName: "cpu").font(.system(size: 13)).foregroundStyle(PalTokens.textSecondary).frame(width: 18)
                    Text("Model, effort and backups").font(.system(size: 12)).foregroundStyle(PalTokens.textPrimary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(PalTokens.textTertiary)
                }
            }
            InspectorSection(title: String(localized: "Messaging"), identifier: "inspectorMessaging") {
                EmptyView()
            } content: {
                InspectorRow(identifier: "profileMessagingRow", action: { router.push(.messagingSettings(botName: botName)) }) {
                    Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 13)).foregroundStyle(PalTokens.textSecondary).frame(width: 18)
                    Text("Messaging settings").font(.system(size: 12)).foregroundStyle(PalTokens.textPrimary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(PalTokens.textTertiary)
                }
                InspectorRow(identifier: "profileTelegramRow", action: { router.push(.telegram(botName: botName)) }) {
                    Image(systemName: "paperplane.fill").font(.system(size: 13)).foregroundStyle(PalTokens.textSecondary).frame(width: 18)
                    Text("Connect Telegram").font(.system(size: 12)).foregroundStyle(PalTokens.textPrimary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(PalTokens.textTertiary)
                }
            }
            InspectorSection(title: String(localized: "Notifications"), identifier: "inspectorNotifications") {
                EmptyView()
            } content: {
                InspectorRow(identifier: "profileNotificationsRow", action: nil) {
                    Text("Notify me when this Bot is done").font(.system(size: 12)).foregroundStyle(PalTokens.textPrimary)
                    Spacer(minLength: 8)
                    Toggle("Notifications", isOn: Binding(get: { profile.notificationsOn }, set: { profile.setNotifications($0) }))
                        .labelsHidden()
                        .toggleStyle(.macSwitch)
                        .accessibilityIdentifier("profileNotificationsToggle")
                }
            }
            if autoApprove.showsSwitch(sessionID: sessionID, upworkConnected: suggestions.services.isConnected(.upwork)) {
                InspectorSection(title: String(localized: "Upwork"), identifier: "inspectorUpwork") {
                    EmptyView()
                } content: {
                    InspectorRow(identifier: "autoApproveRow", action: nil) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Approve Upwork actions automatically in this chat").font(.system(size: 12)).foregroundStyle(PalTokens.textPrimary)
                            Text(autoApprove.didFail(sessionID) ? String(localized: "Couldn't change this. Try again.") : String(localized: "Off by default. Applies to this chat only."))
                                .font(.system(size: 11))
                                .foregroundStyle(PalTokens.textSecondary)
                        }
                        Spacer(minLength: 8)
                        Toggle("Approve Upwork actions automatically in this chat", isOn: Binding(
                            get: { autoApprove.entry(sessionID)?.enabled ?? false },
                            set: { value in Task { await autoApprove.setEnabled(value, sessionID: sessionID) } }
                        ))
                        .labelsHidden()
                        .toggleStyle(.macSwitch)
                        .disabled(autoApprove.isPending(sessionID))
                        .accessibilityIdentifier("autoApproveToggle")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var routinesList: some View {
        switch routines.phase {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 14)
        case .failed:
            InspectorRow(identifier: "routinesFailed", action: { Task { await routines.load() } }) {
                Text("Couldn't load routines. Try again.").font(.system(size: 12)).foregroundStyle(PalTokens.textSecondary)
                Spacer(minLength: 0)
            }
        case .ready where routines.routines.isEmpty:
            InspectorRow(identifier: "routinesEmpty", action: { creation = routines.creationModel() }) {
                Text("No routines yet. Add one").font(.system(size: 12)).foregroundStyle(PalTokens.textSecondary)
                Spacer(minLength: 0)
            }
        case .ready:
            VStack(spacing: 0) {
                ForEach(routines.routines) { routine in
                    InspectorRow(identifier: "routine-\(routine.id)", action: nil) {
                        Image(systemName: "clock").font(.system(size: 13)).foregroundStyle(PalTokens.textTertiary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(routine.title).font(.system(size: 12)).foregroundStyle(PalTokens.textPrimary).lineLimit(1)
                            Text(routine.caption()).font(.system(size: 11)).foregroundStyle(PalTokens.textSecondary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Toggle(routine.title, isOn: Binding(
                            get: { routines.routines.first { $0.id == routine.id }?.isEnabled ?? false },
                            set: { enabled in Task { await routines.setEnabled(enabled, for: routine) } }
                        ))
                        .labelsHidden()
                        .toggleStyle(.macSwitch)
                        .accessibilityLabel(Text(routine.title))
                        .accessibilityIdentifier("routineToggle-\(routine.id)")
                    }
                }
            }
        }
    }
}

private struct InspectorSection<Accessory: View, Content: View>: View {
    let title: String
    let identifier: String
    var first = false
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(PalTokens.textSecondary)
                Spacer()
                accessory
            }
            .padding(.horizontal, 11)
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity)
                .background(PalTokens.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.top, first ? 11 : 24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

private struct InspectorRow<Content: View>: View {
    let identifier: String
    let action: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        if let action {
            Button(action: action) { row }
                .buttonStyle(.plain)
                .accessibilityIdentifier(identifier)
        } else {
            row.accessibilityElement(children: .contain).accessibilityIdentifier(identifier)
        }
    }

    private var row: some View {
        HStack(spacing: 8) { content }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .frame(minHeight: 42)
            .contentShape(Rectangle())
    }
}
#endif
