import Foundation
import PalDesign
import PalRoster
import Testing

@testable import Pal
@testable import PalChat

@MainActor
@Suite("Chat model cache")
struct ChatModelCacheTests {
    private let roster: RosterModel
    private let links: BotLinks
    private let cache = ChatModelCache()

    init() throws {
        roster = try rebuildRoster()
        links = BotLinks(connection: roster.connection)
    }

    private func row(_ name: String) -> BotRow {
        BotRow(
            name: name, isDefault: false, isPrimary: false, isPinned: false, displayName: name, conversationID: nil,
            preview: ClassifiedPreview(kind: .plain, text: ""), lastActive: nil,
            spec: BotAvatarSpec(name: name, uiMeta: nil, photo: nil), accent: nil, usesPrimaryLook: false, sessionIDs: []
        )
    }

    private func model(_ name: String) -> ChatModel { cache.model(for: row(name), links: links, roster: roster) }

    private func transcript(rows count: Int) -> TimelineSnapshot {
        var world = RebuildWorld()
        world.isRunning = false
        for index in 0..<count {
            world.append(rebuildAssistant("a\(index)", "answer \(index)", at: rebuildAt(TimeInterval(index))))
        }
        return world.snapshot(version: 1)
    }

    @Test("a bot that is not on screen gets its model back, with its rows")
    func sameModelComesBack() {
        let first = model("chief")
        first.apply(transcript(rows: 30))
        #expect(model("chief") === first)
        #expect(model("chief").rows.count == 30)
    }

    @Test("a bot whose chat is on screen never shares its model with a second view")
    func activeModelIsNotShared() {
        let shown = model("chief")
        shown.start()
        defer { shown.stop() }
        let second = model("chief")
        #expect(second !== shown)
        shown.stop()
        #expect(model("chief") === shown)
    }

    @Test("only the most recent models stay, the oldest goes first")
    func capacityIsBounded() {
        let first = model("bot0")
        for index in 1...ChatModelCache.capacity { _ = model("bot\(index)") }
        #expect(model("bot0") !== first)
    }

    @Test("a row budget evicts the oldest large chat before the newest one")
    func rowBudgetEvicts() {
        let big = model("big")
        big.apply(transcript(rows: ChatModelCache.rowBudget))
        let other = model("other")
        other.apply(transcript(rows: 10))
        let newest = model("newest")
        newest.apply(transcript(rows: 10))
        _ = model("probe")
        #expect(model("big") !== big)
        #expect(model("newest") === newest)
    }
}
