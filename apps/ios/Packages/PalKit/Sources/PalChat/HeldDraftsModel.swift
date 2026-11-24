import Foundation
import Observation

@MainActor
@Observable
public final class HeldDraftsModel {
    public enum Phase: Sendable, Equatable {
        case idle
        case loading
        case ready
    }

    public private(set) var entries: [HeldDraftEntry] = []
    public private(set) var unreachable: [HeldDraftBot] = []
    public private(set) var phase: Phase = .idle

    private let source: any HeldDraftSource
    private var generation = 0

    public init(source: any HeldDraftSource) {
        self.source = source
    }

    public func entries(for bot: String?) -> [HeldDraftEntry] {
        guard let bot else { return entries }
        return entries.filter { $0.bot.name == bot }
    }

    public func count(for bot: String?) -> Int {
        entries(for: bot).count
    }

    public func load(bots: [HeldDraftBot]) async {
        generation += 1
        let mine = generation
        if entries.isEmpty { phase = .loading }
        let source = source
        let results = await withTaskGroup(of: (Int, Result<[HeldDraft], any Error>).self) { group in
            for (index, bot) in bots.enumerated() {
                group.addTask {
                    do { return (index, .success(try await source.drafts(profile: bot.name))) } catch { return (index, .failure(error)) }
                }
            }
            var collected: [Int: Result<[HeldDraft], any Error>] = [:]
            for await (index, result) in group { collected[index] = result }
            return collected
        }
        guard mine == generation else { return }
        guard !Task.isCancelled else {
            if phase == .loading { phase = .idle }
            return
        }
        var fresh: [HeldDraftEntry] = []
        var missing: [HeldDraftBot] = []
        for (index, bot) in bots.enumerated() {
            switch results[index] {
            case .success(let drafts)?: fresh += drafts.map { HeldDraftEntry(bot: bot, draft: $0) }
            default: missing.append(bot)
            }
        }
        let loaded = Set(bots.map(\.name))
        entries = entries.filter { !loaded.contains($0.bot.name) } + fresh
        unreachable = missing
        phase = .ready
    }

    public func sheet(for entry: HeldDraftEntry) -> HeldDraftSheetModel {
        let source = source
        let profile = entry.bot.name
        return HeldDraftSheetModel(draft: entry.draft) { draft, choice, editedText in
            try await source.answer(profile: profile, draftID: draft.id, choice: choice, editedText: editedText)
        }
    }
}
