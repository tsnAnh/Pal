#if os(macOS)
import PalBotProfile
import PalConnect
import PalDesign
import SwiftUI

struct MacInspector: View {
    let botName: String
    let roster: RosterModel
    let router: AppRouter

    @LazyState private var profile: BotProfileModel
    @LazyState private var routines: RoutinesModel
    @LazyState private var library: LibraryModel
    @LazyState private var suggestions: ConnectedServicesModel
    @State private var creation: NewRoutineModel?

    init(botName: String, roster: RosterModel, router: AppRouter, bots: BotsKit) {
        self.botName = botName
        self.roster = roster
        self.router = router
        _profile = LazyState { BotProfileModel(botName: botName, services: bots.services, roster: roster, sharer: bots.sharer) }
        _routines = LazyState { RoutinesModel(botName: botName, services: bots.services) }
        _library = LazyState { LibraryModel(botName: botName, services: bots.services) }
        _suggestions = LazyState { ConnectedServicesModel(botName: botName, services: bots.services) }
    }

    var body: some View {
        VStack(spacing: 0) {
            InspectorHero(profile: profile)
            InspectorTabs(
                botName: botName,
                router: router,
                profile: profile,
                routines: routines,
                library: library,
                suggestions: suggestions,
                creation: $creation
            )
        }
        .overlay(alignment: .topTrailing) {
            InspectorCloseButton(profile: profile, routines: routines, suggestions: suggestions, creation: $creation)
        }
        .background(PalTokens.content)
        .overlay(alignment: .leading) { PalHairline(axis: .vertical) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("botProfileScreen")
        .task { await routines.load() }
        .task { await suggestions.load() }
        .modifier(InspectorPresentations(profile: profile, routines: routines, creation: $creation))
    }
}

private struct InspectorPresentations: ViewModifier {
    let profile: BotProfileModel
    let routines: RoutinesModel
    @Binding var creation: NewRoutineModel?

    @Environment(ActionAutoApprove.self) private var autoApprove

    func body(content: Content) -> some View {
        content
            .task { await profile.load() }
            .task(id: profile.row?.conversationID) { await autoApprove.load(sessionID: profile.row?.conversationID) }
            .toast(Bindable(profile).toast)
            .macSheet(item: $creation, size: .form) { created in
                NewRoutineSheet(model: created) { creation = nil }
            }
            .macSheet(item: Binding(get: { profile.editing }, set: { if $0 == nil { profile.endEditing() } }), size: .form) { editing in
                EditBotSheet(model: editing) { profile.endEditing() }
            }
            .macConfirm(isPresented: Bindable(profile).confirmsReplacePrimary) {
                MacDialogContent(
                    String(localized: "Replace Primary Bot?"),
                    message: String(localized: "\(profile.displayName) becomes your primary bot. Nothing is copied or deleted."),
                    actions: [
                        MacDialogAction("Replace", identifier: "replacePrimaryConfirm") { Task { await profile.replacePrimary() } },
                        MacDialogAction("Cancel", role: .cancel)
                    ]
                )
            }
    }
}

private struct InspectorCloseButton: View {
    let profile: BotProfileModel
    let routines: RoutinesModel
    let suggestions: ConnectedServicesModel
    @Binding var creation: NewRoutineModel?

    @AppStorage("mac.inspector.suggestionsHidden") private var suggestionsHidden = false
    @Environment(MacShell.self) private var shell

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 8) {
                Menu {
                    Button { profile.beginEditing() } label: { Label("Edit…", palIcon: "square.and.pencil") }
                        .disabled(profile.profile == nil)
                        .accessibilityIdentifier("profileEditButton")
                    Button { creation = routines.creationModel() } label: { Label("New Routine…", palIcon: "plus") }
                        .accessibilityIdentifier("routinesNewButton")
                    if suggestionsHidden, !suggestions.visibleSuggestions.isEmpty {
                        Button { suggestionsHidden = false } label: { Label("Show Suggestions", palIcon: "eye") }
                            .accessibilityIdentifier("inspectorShowSuggestions")
                    }
                    Divider()
                    if !profile.isPrimary {
                        Button { profile.confirmsReplacePrimary = true } label: { Label("Replace Primary Bot…", palIcon: "star") }
                            .accessibilityIdentifier("profileReplacePrimary")
                    }
                    Button { profile.copyID() } label: { Label("Copy ID", palIcon: "doc.on.doc") }
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
                SheetGlassButton(escapes: false, accessibilityIdentifier: "inspectorClose") { shell.showsInspector = false }
            }
        }
        .padding(.top, 12)
        .padding(.trailing, 12)
    }

    private func inspectorGlyph(_ name: String) -> some View {
        PalIcon(name, ink: .secondary)
            .font(.system(size: 12, weight: .regular))
            .frame(width: 32, height: 32)
            .palGlass(Circle())
            .contentShape(Circle())
    }
}

private struct InspectorHero: View {
    let profile: BotProfileModel

    var body: some View {
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
}

private struct InspectorTabs: View {
    let botName: String
    let router: AppRouter
    let profile: BotProfileModel
    let routines: RoutinesModel
    let library: LibraryModel
    let suggestions: ConnectedServicesModel
    @Binding var creation: NewRoutineModel?

    @State private var tab = InspectorTab.activity

    var body: some View {
        VStack(spacing: 0) {
            tabBar.padding(.top, 18).padding(.bottom, 8)
            switch tab {
            case .activity:
                ScrollView {
                    InspectorActivity(
                        botName: botName,
                        router: router,
                        profile: profile,
                        routines: routines,
                        suggestions: suggestions,
                        creation: $creation
                    )
                    .padding(.leading, 12)
                    .padding(.trailing, 15)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.never)
            case .library:
                LibraryView(model: library, showsChrome: false, filters: [.all, .media, .files])
            }
        }
    }

    private var tabBar: some View {
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
}
#endif
