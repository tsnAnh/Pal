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
        let result1 = window.resolve(ids(100..<160)).count
        #expect(result1 == 60)
        let result2 = window.resolve(ids(60..<160)).count
        #expect(result2 == 100)
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
        let result3 = window.resolve(ids(0..<1_010)).count
        #expect(result3 == ChatRowWindow.size + 10)
    }

    @Test func expandingPagesOlderRowsInUntilTheStart() {
        var window = ChatRowWindow()
        let all = ids(0..<1_000)
        _ = window.resolve(all)
        var shown = window.resolve(all).count
        while window.expand(all) { shown = window.resolve(all).count }
        #expect(shown == 1_000)
        let result4 = window.expand(all)
        #expect(!result4)
    }

    @Test func revealingAHiddenRowOpensWindowDownToIt() {
        var window = ChatRowWindow()
        let all = ids(0..<5_000)
        _ = window.resolve(all)
        let result5 = window.reveal("r1000", in: all)
        #expect(result5)
        let range = window.resolve(all)
        #expect(range.lowerBound <= 1_000)
        let result6 = window.reveal("r4999", in: all)
        #expect(!result6)
        let result7 = window.reveal("missing", in: all)
        #expect(!result7)
    }

    @Test func trimShrinksToTheNewestRowsOnlyAboveTheCeiling() {
        var window = ChatRowWindow()
        let all = ids(0..<5_000)
        _ = window.resolve(all)
        let result8 = window.trim(all)
        #expect(!result8)
        window.reveal("r4000", in: all)
        window.reveal("r3000", in: all)
        let result9 = window.resolve(all).count
        #expect(result9 > ChatRowWindow.ceiling)
        let result10 = window.trim(all)
        #expect(result10)
        let result11 = window.resolve(all).count
        #expect(result11 == ChatRowWindow.size)
    }

    @Test func aMissingStartRowFallsBackToTheNewestRows() {
        var window = ChatRowWindow()
        _ = window.resolve(ids(0..<1_000))
        let result12 = window.resolve(ids(5_000..<6_000)).count
        #expect(result12 == ChatRowWindow.size)
    }
}
