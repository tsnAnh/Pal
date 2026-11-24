import Foundation
import PalClient
import PalProtocol
import PalRoster
import Testing

@testable import Pal
@testable import PalChat

@MainActor
private struct SwitchWorld {
    let roster: RosterModel
    let links: BotLinks
    let store: ChatLastSeenStore

    init() throws {
        roster = try rebuildRoster()
        links = BotLinks(connection: roster.connection)
        store = ChatLastSeenStore(defaults: try #require(UserDefaults(suiteName: "chat-switch-\(UUID().uuidString)")))
    }

    func model(_ name: String) -> ChatModel {
        let row = BotRow(
            name: name, isDefault: false, isPrimary: false, isPinned: false, displayName: name, conversationID: nil,
            preview: ClassifiedPreview(kind: .plain, text: ""), lastActive: nil,
            spec: BotAvatarSpec(name: name, uiMeta: nil, photo: nil), accent: nil, usesPrimaryLook: false, sessionIDs: []
        )
        return ChatModel(bot: row, links: links, roster: roster, lastSeenStore: store)
    }

    func transcript(rows count: Int, version: UInt64 = 1) -> TimelineSnapshot {
        var world = RebuildWorld()
        world.isRunning = false
        for index in 0..<count {
            let at = rebuildAt(TimeInterval(index * 60))
            let item = index.isMultiple(of: 2)
                ? rebuildUser("u\(index)", "question \(index)", at: at)
                : rebuildAssistant("a\(index)", "answer \(index)", at: at)
            world.append(item)
        }
        return world.snapshot(version: version)
    }

    func visited(_ name: String, rows count: Int) {
        let model = model(name)
        model.apply(transcript(rows: count))
        model.stop()
    }
}

@MainActor
@Suite("Switching between bot chats")
struct ChatModelSwitchTests {
    @Test("a chat opened again shows its rows before any cache read, never an empty list", arguments: [160, 82, 47])
    func reopenedChatHasRowsAtOnce(count: Int) throws {
        let world = try SwitchWorld()
        world.visited("chief", rows: count)
        world.visited("mobile", rows: 12)
        let reopened = world.model("chief")
        #expect(reopened.rows.count == count)
        #expect(!reopened.windowRows.isEmpty)
        #expect(!reopened.isOpening)
        #expect(!reopened.openStats.clearedAfterData)
    }

    @Test("only the last four chats stay in memory")
    func memoryIsBounded() throws {
        let world = try SwitchWorld()
        let names = (0..<(ChatSnapshotMemory.capacity + 1)).map { "bot\($0)" }
        for name in names { world.visited(name, rows: 5) }
        #expect(world.model(names[0]).rows.isEmpty)
        for name in names.dropFirst() { #expect(world.model(name).rows.count == 5) }
    }

    @Test("a snapshot without a session and without rows never empties a chat that has rows")
    func unresolvedEmptySnapshotKeepsRows() throws {
        let world = try SwitchWorld()
        world.visited("chief", rows: 47)
        let reopened = world.model("chief")
        var unresolved = world.transcript(rows: 0, version: 1)
        unresolved.sessionID = nil
        reopened.apply(unresolved)
        #expect(reopened.rows.count == 47)
        #expect(!reopened.openStats.clearedAfterData)
    }

    @Test("the fresh snapshot replaces the cached rows in place, keeping every row id")
    func freshReplacesCachedInPlace() throws {
        let world = try SwitchWorld()
        world.visited("chief", rows: 82)
        let reopened = world.model("chief")
        let cachedIDs = reopened.rowIDs
        reopened.apply(world.transcript(rows: 83, version: 1))
        #expect(Array(reopened.rowIDs.prefix(cachedIDs.count)) == cachedIDs)
        #expect(reopened.rowIDs.count == cachedIDs.count + 1)
        #expect(!reopened.openStats.clearedAfterData)
    }

    @Test("a resolved session that really is empty still clears, and the clear is counted")
    func resolvedEmptyClearsAndCounts() throws {
        let world = try SwitchWorld()
        world.visited("chief", rows: 30)
        let reopened = world.model("chief")
        reopened.apply(world.transcript(rows: 0, version: 2))
        #expect(reopened.rows.isEmpty)
        #expect(reopened.openStats.clearedAfterData)
    }
}
