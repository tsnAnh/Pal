import XCTest

final class SpikeUITests: XCTestCase {
    func drive(_ variant: String, deferUntilIdle: Bool = false, extra: [String] = [], tag: String = "") {
        let app = XCUIApplication()
        let env = ProcessInfo.processInfo.environment
        let dir = env["SPIKE_DIR"] ?? NSTemporaryDirectory()
        app.launchArguments = ["-variant", variant, "-defer", deferUntilIdle ? "YES" : "NO", "-total", "400"] + extra
        app.launchEnvironment["SPIKE_OUT"] = "\(dir)/spike-\(variant)\(deferUntilIdle ? "-defer" : "")\(tag).jsonl"
        app.launch()
        #if os(iOS)
        let list = app.scrollViews.firstMatch
        #else
        let list = app.windows.firstMatch
        #endif
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1.5)
        let status = app.staticTexts["status"]
        for i in 0..<400 {
            if status.label == "top" { break }
            #if os(iOS)
            let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            if i % 3 == 2 {
                list.swipeDown(velocity: .fast)
                Thread.sleep(forTimeInterval: 0.4)
            } else {
                let to = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                from.press(forDuration: 0.05, thenDragTo: to, withVelocity: 250, thenHoldForDuration: 0.3)
                Thread.sleep(forTimeInterval: 0.2)
            }
            #else
            list.scroll(byDeltaX: 0, deltaY: i % 3 == 2 ? 900 : 250)
            Thread.sleep(forTimeInterval: 0.2)
            #endif
        }
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(status.label, "top")
        app.terminate()
    }

    func testCurrent() { drive("current") }
    func testLegacy() { drive("legacy") }
    func testTrack() { drive("track") }
    func testDelta() { drive("delta") }
    func testLegacyDefer() { drive("legacy", deferUntilIdle: true) }
    func testTrackDefer() { drive("track", deferUntilIdle: true) }
    func testBottom() { drive("bottom") }
    func testFlipped() { drive("flipped") }
    func stream(_ variant: String, insert: Bool = false) {
        let app = XCUIApplication()
        let dir = ProcessInfo.processInfo.environment["SPIKE_DIR"] ?? NSTemporaryDirectory()
        app.launchArguments = ["-variant", variant, "-total", "400", "-appends", "YES", "-insertNew", insert ? "YES" : "NO"]
        app.launchEnvironment["SPIKE_OUT"] = "\(dir)/spike-\(variant)-\(insert ? "insert" : "stream").jsonl"
        app.launch()
        #if os(iOS)
        let list = app.scrollViews.firstMatch
        #else
        let list = app.windows.firstMatch
        #endif
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1.5)
        for _ in 0..<5 {
            #if os(iOS)
            list.swipeDown(velocity: .slow)
            #else
            list.scroll(byDeltaX: 0, deltaY: 400)
            #endif
            Thread.sleep(forTimeInterval: 6)
        }
        app.terminate()
    }

    func testFlippedStream() { stream("flipped") }
    func testFlippedCompStream() { stream("flippedComp") }
    func testFlippedComp() { drive("flippedComp") }
    func testFlippedInsert() { stream("flipped", insert: true) }
    func testFlippedAnchorStream() { stream("flippedAnchor") }
    func testFlippedAnchor() { drive("flippedAnchor") }
    func testFlippedNoop() { drive("flipped", extra: ["-noop", "YES"], tag: "-noop") }
}
