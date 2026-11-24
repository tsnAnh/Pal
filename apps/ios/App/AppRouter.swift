import PalClient
import PalRoster
import Observation
#if os(iOS)
import UIKit
#endif

enum AppRoute: Hashable {
    case chat(botName: String)
    case botProfile(botName: String)
    case botThread(BotThreadRoute)
    case library(botName: String)
    case routines(botName: String)
    case slack(botName: String)
    case discord(botName: String)
    case telegram(botName: String)
    case messagingSettings(botName: String)
    case botModel(botName: String)
    case botKeys(botName: String)
    case botVault(botName: String)
    case computer(botName: String)
    case room(roomID: String)
    case kanban
}

enum AppSheet: String, Identifiable {
    case settings
    case createBot
    case connectApps
    case kanban
    case approvals

    var id: String { rawValue }
}

enum AppCapability: Hashable {
    case botProfile
    case shareAsTemplate
    case connectApps
    case kanban
}

enum BotMenuAction: CaseIterable, Identifiable {
    case viewProfile
    case shareAsTemplate

    var id: Self { self }
}

@MainActor
@Observable
final class AppRouter {
    var path: [AppRoute] = []
    var sheet: AppSheet?
    var isSearching = false
    var renamingBot: String?
    var deletingBot: String?
    let searchScopes: [SearchScope] = [.all, .messages, .bots]
    private(set) var capabilities: Set<AppCapability>
    private(set) var connectAppsProfile: String?
    private(set) var approvalsProfile: String?
    private(set) var settingsRoute: SettingsRoute?
    @ObservationIgnored private var shareAsTemplateHandler: ((String) -> Void)?

    init(capabilities: Set<AppCapability> = []) {
        self.capabilities = capabilities
    }

    func push(_ route: AppRoute) {
        path.append(route)
    }

    func present(_ sheet: AppSheet) {
        if sheet == .settings { settingsRoute = nil }
        self.sheet = sheet
    }

    func presentSettings(route: SettingsRoute) {
        settingsRoute = route
        sheet = .settings
    }

    func presentConnectApps(profile: String? = nil) {
        connectAppsProfile = profile
        sheet = .connectApps
    }

    func presentApprovals(profile: String? = nil) {
        approvalsProfile = profile
        sheet = .approvals
    }

    func presentKanban() {
        if Self.pushesKanban {
            if path.last != .kanban { push(.kanban) }
        } else {
            sheet = .kanban
        }
    }

    var isKanbanPresented: Bool {
        get { sheet == .kanban }
        set { if !newValue, sheet == .kanban { dismissSheet() } }
    }

    private static var pushesKanban: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    func dismissSheet() {
        sheet = nil
    }

    func openSearch() {
        isSearching = true
    }

    func closeSearch() {
        isSearching = false
    }

    func pop() {
        if !path.isEmpty { path.removeLast() }
    }

    func popToRoot() {
        path.removeAll()
    }

    func openChat(botName: String) {
        isSearching = false
        sheet = nil
        if path.last != .chat(botName: botName) { path = [.chat(botName: botName)] }
    }

    func openSlack(botName: String) {
        isSearching = false
        sheet = nil
        if path.last != .slack(botName: botName) { push(.slack(botName: botName)) }
    }

    func openRoom(id roomID: String) {
        isSearching = false
        sheet = nil
        if path.last != .room(roomID: roomID) { path = [.room(roomID: roomID)] }
    }

    func supports(_ action: BotMenuAction) -> Bool {
        switch action {
        case .viewProfile: capabilities.contains(.botProfile)
        case .shareAsTemplate: capabilities.contains(.shareAsTemplate)
        }
    }

    func registerShareAsTemplate(_ handler: @escaping (String) -> Void) {
        shareAsTemplateHandler = handler
        capabilities.insert(.shareAsTemplate)
    }

    func perform(_ action: BotMenuAction, botName: String) {
        guard supports(action) else { return }
        switch action {
        case .viewProfile: push(.botProfile(botName: botName))
        case .shareAsTemplate: shareAsTemplateHandler?(botName)
        }
    }

    func openChat(from target: PushTarget, in roster: RosterModel) {
        let name = roster.bot(named: target.profile)?.name
            ?? target.sessionID.flatMap { roster.botName(forSessionID: $0) }
            ?? target.profile
        openChat(botName: name)
    }

    func dropUnresolvedChat(in roster: RosterModel) {
        guard roster.isLoaded, case .chat(let name)? = path.last, roster.bot(named: name) == nil else { return }
        popToRoot()
    }

    @discardableResult
    func openChat(sessionID: String, in roster: RosterModel) -> Bool {
        guard let name = roster.botName(forSessionID: sessionID) else { return false }
        openChat(botName: name)
        return true
    }
}
