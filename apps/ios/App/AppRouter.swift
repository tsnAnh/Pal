import HermesRoster
import Observation

enum AppRoute: Hashable {
    case chat(botName: String)
    case botProfile(botName: String)
    case botThread(BotThreadRoute)
}

enum AppSheet: String, Identifiable {
    case settings
    case createBot

    var id: String { rawValue }
}

enum AppCapability: Hashable {
    case botProfile
    case shareAsTemplate
    case connectApps
}

enum BotMenuAction: CaseIterable, Identifiable {
    case viewProfile
    case findInChat
    case shareAsTemplate

    var id: Self { self }
}

@MainActor
@Observable
final class AppRouter {
    var path: [AppRoute] = []
    var sheet: AppSheet?
    var isSearching = false
    let searchScopes: [SearchScope] = [.all, .messages, .bots]
    private(set) var capabilities: Set<AppCapability>
    @ObservationIgnored private var shareAsTemplateHandler: ((String) -> Void)?

    init(capabilities: Set<AppCapability> = []) {
        self.capabilities = capabilities
    }

    func push(_ route: AppRoute) {
        path.append(route)
    }

    func present(_ sheet: AppSheet) {
        self.sheet = sheet
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

    func popToRoot() {
        path.removeAll()
    }

    func openChat(botName: String) {
        isSearching = false
        sheet = nil
        if path.last != .chat(botName: botName) { path = [.chat(botName: botName)] }
    }

    func supports(_ action: BotMenuAction) -> Bool {
        switch action {
        case .findInChat: true
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
        case .findInChat: break
        }
    }

    @discardableResult
    func openChat(sessionID: String, in roster: RosterModel) -> Bool {
        guard let name = roster.botName(forSessionID: sessionID) else { return false }
        openChat(botName: name)
        return true
    }
}
