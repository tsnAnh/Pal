import PalDesign
import PalDiagnostics
import PalRoster

extension LookPalette {
    static let catalog = LookPalette(kinds: BotLookCatalog.shapes.map(\.rawValue), colors: BotLookCatalog.swatches.map(\.hex))
}

extension RosterModel {
    func didApplyFirstSnapshot(_ profiles: [RosterProfile]) {
        LaunchClock.mark("roster live snapshot applied (\(profiles.count) bots)", on: .osLog())
        logSidebarRows()
        let candidates = profiles.filter(LooklessFill.isEligible)
        guard !candidates.isEmpty else { return }
        let filler = LooklessFiller(gateway: gateway, palette: .catalog, diagnostics: .osLog())
        Task { await filler.fill(candidates) }
    }

    private func logSidebarRows() {
        let diagnostics = Diagnostics.osLog()
        for bot in bots {
            let sizes = "displayName \(bot.displayName.count) chars, preview \(bot.preview.text.count) chars"
            diagnostics.info("roster", "sidebar row \(bot.name): \(sizes), primary \(bot.isPrimary), pinned \(bot.isPinned)")
        }
    }
}
