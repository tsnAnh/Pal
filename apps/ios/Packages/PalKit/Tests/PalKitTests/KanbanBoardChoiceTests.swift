import Foundation
import PalKanban
import PalProtocol
import Testing

@Suite("Kanban board choice")
struct KanbanBoardChoiceTests {
    @Test func lastOpenedBoardWins() {
        #expect(KanbanBoardChoice.pick(boards: ["default", "ops"], last: "ops") == "ops")
    }

    @Test func theOnlyBoardOpensWithoutAList() {
        #expect(KanbanBoardChoice.pick(boards: ["ops"], last: nil) == "ops")
    }

    @Test func defaultBoardIsPreferredAmongMany() {
        #expect(KanbanBoardChoice.pick(boards: ["ops", "default", "infra"], last: nil) == "default")
    }

    @Test func firstBoardWhenThereIsNoDefault() {
        #expect(KanbanBoardChoice.pick(boards: ["ops", "infra"], last: nil) == "ops")
    }

    @Test func unknownLastBoardFallsBack() {
        #expect(KanbanBoardChoice.pick(boards: ["ops", "default"], last: "gone") == "default")
        #expect(KanbanBoardChoice.pick(boards: [], last: "gone") == nil)
    }

    @Test func pickerWheneverABoardExists() {
        #expect(!KanbanBoardChoice.showsPicker(boards: []))
        #expect(KanbanBoardChoice.showsPicker(boards: ["default"]))
        #expect(KanbanBoardChoice.showsPicker(boards: ["default", "ops"]))
    }

    @Test func persistedChoiceSurvivesAndIsPerAccount() async {
        let cache = CacheStore(root: FileManager.default.temporaryDirectory.appending(path: "kanban-last-\(UUID().uuidString)", directoryHint: .isDirectory))
        KanbanDiskCache(store: cache, account: "https://gw.example|me").saveLastBoard("ops")
        #expect(await KanbanDiskCache(store: cache, account: "https://gw.example|me").lastBoard() == "ops")
        #expect(await KanbanDiskCache(store: cache, account: "https://gw.example|other").lastBoard() == nil)
        cache.removeAll()
        #expect(await KanbanDiskCache(store: cache, account: "https://gw.example|me").lastBoard() == nil)
    }

    @Test func oversizedSlugIsNotPersisted() async {
        let cache = CacheStore(root: FileManager.default.temporaryDirectory.appending(path: "kanban-last-\(UUID().uuidString)", directoryHint: .isDirectory))
        let disk = KanbanDiskCache(store: cache, account: "a")
        disk.saveLastBoard(String(repeating: "x", count: KanbanBoardChoice.maxSlugLength + 1))
        #expect(await disk.lastBoard() == nil)
    }
}
