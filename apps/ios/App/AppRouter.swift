import Observation

enum AppRoute: Hashable {
    case chat(botName: String)
}

enum AppSheet: String, Identifiable {
    case settings

    var id: String { rawValue }
}

@MainActor
@Observable
final class AppRouter {
    var path: [AppRoute] = []
    var sheet: AppSheet?

    func push(_ route: AppRoute) {
        path.append(route)
    }

    func present(_ sheet: AppSheet) {
        self.sheet = sheet
    }

    func dismissSheet() {
        sheet = nil
    }

    func popToRoot() {
        path.removeAll()
    }

    @discardableResult
    func openChat(sessionID: String, in roster: RosterModel) -> Bool {
        guard let name = roster.botName(forSessionID: sessionID) else { return false }
        if path.last != .chat(botName: name) { path = [.chat(botName: name)] }
        return true
    }
}
