import AppIntents
import CoreSpotlight
import HermesDiagnostics

@MainActor
final class BotDirectory {
    private var published: Set<String> = []
    private let diagnostics = Diagnostics.osLog()

    func publish(_ bots: [BotRow]) async {
        HermesBotsShortcuts.updateAppShortcutParameters()
        let entities = bots.map(BotEntity.init)
        let current = Set(entities.map(\.id))
        let stale = published.subtracting(current)
        let index = CSSearchableIndex.default()
        do {
            try await index.indexAppEntities(entities)
            if !stale.isEmpty {
                try await index.deleteAppEntities(identifiedBy: Array(stale), ofType: BotEntity.self)
            }
            published = current
        } catch {
            diagnostics.warning("intents", "bot index not updated: \(Diagnostics.describe(error))")
        }
    }
}
