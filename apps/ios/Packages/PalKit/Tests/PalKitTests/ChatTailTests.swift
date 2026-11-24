import PalChat
import Testing

private func ids(_ count: Int) -> [String] { (0..<count).map { "r\($0)" } }
private func flat(_ value: Double) -> (String) -> Double { { _ in value } }

@Suite("Chat tail")
struct ChatTailTests {
    @Test func theFirstPlanCoversOneAndAHalfViewportsAndHidesTheRestExactly() {
        var tail = ChatTail()
        let rows = ids(161)
        let plan = tail.plan(ids: rows, viewport: 983, height: flat(222))
        let rendered = rows.count - plan.start
        #expect(plan.start > 0)
        #expect(rendered >= ChatTail.minimumRows && rendered <= 20)
        #expect(Double(rendered) * 222 >= ChatTail.viewports * 983)
        #expect(plan.hiddenHeight == Double(plan.start) * 222)
        #expect(plan.hiddenHeight + Double(rendered) * 222 == 161 * 222)
    }

    @Test func hiddenHeightIsTheSumOfTheActualHiddenRows() {
        var tail = ChatTail()
        let rows = ids(60)
        let heights: (String) -> Double = { Double(Int($0.dropFirst())! + 10) }
        let plan = tail.plan(ids: rows, viewport: 400, height: heights)
        let expected = rows[..<plan.start].reduce(0.0) { $0 + heights($1) }
        #expect(plan.hiddenHeight == expected)
    }

    @Test func aMissingViewportRendersTheFallbackRows() {
        var tail = ChatTail()
        let rows = ids(100)
        let plan = tail.plan(ids: rows, viewport: nil, height: flat(222))
        #expect(rows.count - plan.start == ChatTail.fallbackRows)
    }

    @Test func appendingRowsKeepsTheStart() {
        var tail = ChatTail()
        var rows = ids(100)
        _ = tail.plan(ids: rows, viewport: 983, height: flat(222))
        let id = tail.startID
        rows += ["new1", "new2"]
        let plan = tail.plan(ids: rows, viewport: 983, height: flat(222))
        #expect(tail.startID == id)
        #expect(rows[plan.start] == id)
    }

    @Test func aMissingStartReplans() {
        var tail = ChatTail()
        _ = tail.plan(ids: ids(100), viewport: 983, height: flat(222))
        let other = (0..<100).map { "x\($0)" }
        let plan = tail.plan(ids: other, viewport: 983, height: flat(222))
        #expect(plan.start > 0)
        #expect(other[plan.start] == tail.startID)
    }

    @Test func extendRevealsAPageAndTheDeficitThenReachesTheTop() {
        var tail = ChatTail()
        let rows = ids(200)
        let first = tail.plan(ids: rows, viewport: 983, height: flat(222))
        let firstExtend = tail.extend(ids: rows, deficit: 0, height: flat(222))
        #expect(firstExtend)
        let second = tail.start(in: rows)
        #expect(first.start - second >= ChatTail.pageRows)
        let secondExtend = tail.extend(ids: rows, deficit: 5000, height: flat(222))
        #expect(secondExtend)
        let third = tail.start(in: rows)
        #expect(Double(second - third) * 222 >= 5000)
        var guardCount = 0
        while guardCount < 100 {
            let moved = tail.extend(ids: rows, deficit: 1000, height: flat(222))
            if !moved { break }
            guardCount += 1
        }
        #expect(tail.start(in: rows) == 0)
        let atTop = tail.extend(ids: rows, deficit: 1000, height: flat(222))
        #expect(!atTop)
        let plan = tail.plan(ids: rows, viewport: 983, height: flat(222))
        #expect(plan.start == 0 && plan.hiddenHeight == 0)
    }

    @Test func revealBringsAnOldRowIntoRangeWithMargin() {
        var tail = ChatTail()
        let rows = ids(200)
        _ = tail.plan(ids: rows, viewport: 983, height: flat(222))
        let revealed = tail.reveal("r50", in: rows)
        #expect(revealed)
        #expect(tail.start(in: rows) == 46)
        let again = tail.reveal("r50", in: rows)
        let newest = tail.reveal("r199", in: rows)
        let missing = tail.reveal("missing", in: rows)
        #expect(!again && !newest && !missing)
    }

    @Test func aShortListRendersEverything() {
        var tail = ChatTail()
        let rows = ids(5)
        let plan = tail.plan(ids: rows, viewport: 983, height: flat(222))
        #expect(plan == ChatTailPlan(start: 0, hiddenHeight: 0))
        #expect(tail.plan(ids: [], viewport: 983, height: flat(222)) == ChatTailPlan(start: 0, hiddenHeight: 0))
    }
}
