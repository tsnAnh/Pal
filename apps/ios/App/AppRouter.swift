import HermesRoster
import Observation

enum AppRoute: Hashable {
    case chat(botName: String)
}

enum AppSheet: String, Identifiable {
    case settings
    case createBot

    var id: String { rawValue }
}

struct AppCapabilities: Equatable {
    var connectApps = false
    var searchScopes: [SearchScope] = [.all, .messages, .bots]
}

@MainActor
@Observable
final class AppRouter {
    var path: [AppRoute] = []
    var sheet: AppSheet?
    var isSearching = false
    var capabilities = AppCapabilities()

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

    @discardableResult
    func openChat(sessionID: String, in roster: RosterModel) -> Bool {
        guard let name = roster.botName(forSessionID: sessionID) else { return false }
        openChat(botName: name)
        return true
    }
}
