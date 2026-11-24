import PalChat
import Testing

@Suite("Chat row height cache")
struct ChatRowHeightCacheTests {
    @Test func recordedHeightsReadBackAtTheSameWidth() {
        var cache = ChatRowHeightCache()
        cache.record("a", height: 44, width: 390)
        #expect(cache.height(for: "a", width: 390) == 44)
        #expect(cache.height(for: "a", width: 390.4) == 44)
        #expect(cache.height(for: "b", width: 390) == nil)
        #expect(cache.count == 1)
    }

    @Test func aWidthChangeClearsEverythingAndAdoptsTheNewWidth() {
        var cache = ChatRowHeightCache()
        cache.record("a", height: 44, width: 390)
        cache.record("b", height: 60, width: 390)
        #expect(cache.height(for: "a", width: 500) == nil)
        cache.record("c", height: 30, width: 500)
        #expect(cache.count == 1)
        #expect(cache.width == 500)
        #expect(cache.height(for: "c", width: 500) == 30)
        #expect(cache.height(for: "a", width: 390) == nil)
    }

    @Test func invalidatingOneIDKeepsTheOthers() {
        var cache = ChatRowHeightCache()
        cache.record("a", height: 44, width: 390)
        cache.record("b", height: 60, width: 390)
        cache.invalidate("a")
        #expect(cache.height(for: "a", width: 390) == nil)
        #expect(cache.height(for: "b", width: 390) == 60)
        cache.invalidate("missing")
        #expect(cache.count == 1)
    }

    @Test func overCapacityEvictsTheLeastRecentlyRecorded() {
        var cache = ChatRowHeightCache(capacity: 3)
        for id in ["a", "b", "c"] { cache.record(id, height: 10, width: 390) }
        cache.record("a", height: 12, width: 390)
        cache.record("d", height: 10, width: 390)
        #expect(cache.count == 3)
        #expect(cache.height(for: "b", width: 390) == nil)
        #expect(cache.height(for: "a", width: 390) == 12)
        #expect(cache.height(for: "c", width: 390) == 10)
        #expect(cache.height(for: "d", width: 390) == 10)
    }

    @Test func nonPositiveHeightsAreIgnored() {
        var cache = ChatRowHeightCache()
        cache.record("a", height: 0, width: 390)
        cache.record("b", height: -5, width: 390)
        #expect(cache.count == 0)
        cache.record("c", height: 20, width: 390)
        cache.record("c", height: 0, width: 390)
        #expect(cache.height(for: "c", width: 390) == 20)
    }

    @Test func unmeasuredPicksTheNewestRowsWithoutAHeightUpToTheLimit() {
        var cache = ChatRowHeightCache()
        cache.record("c", height: 40, width: 390)
        let ids = ["a", "b", "c", "d", "e"]
        #expect(cache.unmeasured(in: ids, width: 390, limit: 2) == ["e", "d"])
        #expect(cache.unmeasured(in: ids, width: 390, limit: 10) == ["e", "d", "b", "a"])
        #expect(cache.unmeasured(in: ids, width: 390, skipping: ["e"], limit: 2) == ["d", "b"])
        #expect(cache.unmeasured(in: ids, width: 390, limit: 0).isEmpty)
    }

    @Test func aNewWidthLeavesEveryRowUnmeasured() {
        var cache = ChatRowHeightCache()
        cache.record("a", height: 40, width: 390)
        #expect(cache.unmeasured(in: ["a"], width: 500, limit: 1) == ["a"])
    }
}

@Suite("Chat row height cache rerecord")
struct ChatRowHeightCacheRerecordTests {
    @Test func aRerecordAtTheSameWidthReplacesOnlyThatRow() {
        var cache = ChatRowHeightCache()
        cache.record("a", height: 44, width: 390)
        cache.record("b", height: 60, width: 390)
        cache.record("a", height: 50, width: 390.3)
        #expect(cache.height(for: "a", width: 390) == 50)
        #expect(cache.height(for: "b", width: 390) == 60)
    }
}
