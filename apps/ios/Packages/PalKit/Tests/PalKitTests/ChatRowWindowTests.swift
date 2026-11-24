import PalChat
import Testing

@Suite("Chat row window")
struct ChatRowWindowTests {
    private func ids(_ range: Range<Int>) -> [String] { range.map { "r\($0)" } }

    @Test func aLongTranscriptShowsOnlyTheNewestRows() {
        var window = ChatRowWindow()
        let all = ids(0..<15_000)
        let range = window.resolve(all)
        #expect(range.count == ChatRowWindow.size)
        #expect(range.upperBound == all.count)
    }

    @Test func aShortTranscriptShowsEverythingAndFollowsOlderRowsPrepended() {
        var window = ChatRowWindow()
        #expect(window.resolve(ids(100..<160)).count == 60)
        #expect(window.resolve(ids(60..<160)).count == 100)
    }

    @Test func olderRowsFetchedBeyondTheWindowStayHiddenSoNothingMoves() {
        var window = ChatRowWindow()
        let base = ids(0..<1_000)
        _ = window.resolve(base)
        let withOlder = (0..<100).map { "o\($0)" } + base
        let range = window.resolve(withOlder)
        #expect(range.count == ChatRowWindow.size)
        #expect(withOlder[range.lowerBound] == "r800")
    }

    @Test func appendedRowsGrowTheWindowFromTheFixedStart() {
        var window = ChatRowWindow()
        _ = window.resolve(ids(0..<1_000))
        #expect(window.resolve(ids(0..<1_010)).count == ChatRowWindow.size + 10)
    }

    @Test func expandingPagesOlderRowsInUntilTheStart() {
        var window = ChatRowWindow()
        let all = ids(0..<1_000)
        _ = window.resolve(all)
        var shown = window.resolve(all).count
        while window.expand(all) { shown = window.resolve(all).count }
        #expect(shown == 1_000)
        #expect(!window.expand(all))
    }

    @Test func revealingAHiddenRowOpensWindowDownToIt() {
        var window = ChatRowWindow()
        let all = ids(0..<5_000)
        _ = window.resolve(all)
        #expect(window.reveal("r1000", in: all))
        let range = window.resolve(all)
        #expect(range.lowerBound <= 1_000)
        #expect(!window.reveal("r4999", in: all))
        #expect(!window.reveal("missing", in: all))
    }

    @Test func trimShrinksToTheNewestRowsOnlyAboveTheCeiling() {
        var window = ChatRowWindow()
        let all = ids(0..<5_000)
        _ = window.resolve(all)
        #expect(!window.trim(all))
        window.reveal("r4000", in: all)
        window.reveal("r3000", in: all)
        #expect(window.resolve(all).count > ChatRowWindow.ceiling)
        #expect(window.trim(all))
        #expect(window.resolve(all).count == ChatRowWindow.size)
    }

    @Test func aMissingStartRowFallsBackToTheNewestRows() {
        var window = ChatRowWindow()
        _ = window.resolve(ids(0..<1_000))
        #expect(window.resolve(ids(5_000..<6_000)).count == ChatRowWindow.size)
    }
}
