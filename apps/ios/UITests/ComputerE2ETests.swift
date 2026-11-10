import XCTest

@MainActor
final class ComputerE2ETests: ComputerTestCase {
    func test1ProfileOpensTheLiveDesktopInWatchMode() throws {
        let app = signedInApp()
        openComputer(app)
        waitForStatus(app, "watching")
        XCTAssertTrue(element(app, "computerTakeControl").isEnabled)
        XCTAssertFalse(element(app, "computerImDone").exists)
        shot(app, "computer-watching")
    }

    #if os(iOS)
    func test2WatchModeSendsNothingToTheScreen() throws {
        let app = signedInApp()
        openComputer(app)
        waitForStatus(app, "watching")
        surfacePoint(app, x: 0.5, y: 0.5).tap()
        Thread.sleep(forTimeInterval: 1.5)
        shot(app, "computer-watch-tap")
    }

    func test3TakeControlClicksTypesAndHandsBack() throws {
        let app = signedInApp()
        openComputer(app)
        waitForStatus(app, "watching")
        element(app, "computerTakeControl").tap()
        waitForStatus(app, "controlling")
        waitFor(element(app, "computerImDone"), timeout: 10, "I'm done")
        shot(app, "computer-controlling")

        surfacePoint(app, x: 0.25, y: 0.5).tap()
        Thread.sleep(forTimeInterval: 1)
        shot(app, "computer-clicked-left-quarter")

        element(app, "computerSurface").coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).press(forDuration: 1)
        Thread.sleep(forTimeInterval: 1)
        shot(app, "computer-right-click")

        element(app, "computerKeyboardButton").tap()
        app.typeText("hello")
        Thread.sleep(forTimeInterval: 1)
        shot(app, "computer-typed")
        element(app, "computerKeyboardButton").tap()

        element(app, "computerImDone").tap()
        waitForStatus(app, "watching")
        XCTAssertFalse(element(app, "computerImDone").exists)
        shot(app, "computer-handed-back")
    }

    func test4TrackpadModeMovesThePointerByDragAndClicksThere() throws {
        let app = signedInApp()
        openComputer(app)
        waitForStatus(app, "watching")
        element(app, "computerTakeControl").tap()
        waitForStatus(app, "controlling")
        element(app, "computerMoreButton").tap()
        let toggle = app.buttons["Trackpad mode"]
        waitFor(toggle, timeout: 10, "trackpad toggle")
        toggle.tap()
        let surface = element(app, "computerSurface")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)))
        Thread.sleep(forTimeInterval: 1)
        shot(app, "computer-trackpad-moved")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.9)).tap()
        Thread.sleep(forTimeInterval: 1)
        shot(app, "computer-trackpad-clicked")
        element(app, "computerMoreButton").tap()
        let recenter = app.buttons["Recenter pointer"]
        waitFor(recenter, timeout: 10, "recenter")
        recenter.tap()
        element(app, "computerImDone").tap()
        waitForStatus(app, "watching")
    }

    func test5PinchZoomsAndTwoFingerDragPansWhenZoomedIn() throws {
        let app = signedInApp()
        openComputer(app)
        waitForStatus(app, "watching")
        let surface = element(app, "computerSurface")
        surface.pinch(withScale: 3, velocity: 2)
        Thread.sleep(forTimeInterval: 1)
        shot(app, "computer-zoomed")
        surface.swipeLeft()
        Thread.sleep(forTimeInterval: 1)
        shot(app, "computer-zoomed-panned")
    }
    #endif

    #if os(macOS)
    func test2WatchModeSendsNothingToTheScreen() throws {
        let app = signedInApp()
        openComputer(app)
        waitForStatus(app, "watching")
        let before = try inputLog().count
        surfacePoint(app, x: 0.5, y: 0.5).click()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(try inputLog().count, before, "watching sends nothing to the screen")
        shot(app, "computer-watch-click")
    }

    func test3TakeControlClicksTypesAndHandsBack() throws {
        let app = signedInApp()
        openComputer(app)
        waitForStatus(app, "watching")
        element(app, "computerTakeControl").hit()
        waitForStatus(app, "controlling")
        waitFor(element(app, "computerImDone"), timeout: 10, "I'm done")
        shot(app, "computer-controlling")

        var mark = try inputLog().count
        surfacePoint(app, x: 0.25, y: 0.5).click()
        try waitForInput(after: mark, containing: "pointer buttons=1", "left press")
        try waitForInput(after: mark, containing: "pointer buttons=0", "left release")
        shot(app, "computer-clicked-left-quarter")

        mark = try inputLog().count
        surfacePoint(app, x: 0.75, y: 0.5).rightClick()
        try waitForInput(after: mark, containing: "pointer buttons=4", "right press")
        shot(app, "computer-right-click")

        mark = try inputLog().count
        app.typeText("hi")
        try waitForInput(after: mark, containing: "key down=1 keysym=0x68", "h down")
        try waitForInput(after: mark, containing: "key down=1 keysym=0x69", "i down")
        shot(app, "computer-typed")

        mark = try inputLog().count
        app.typeKey("c", modifierFlags: .command)
        try waitForInput(after: mark, containing: "key down=1 keysym=0xffe3", "command acts as control")
        try waitForInput(after: mark, containing: "key down=1 keysym=0x63", "c down")

        element(app, "computerImDone").hit()
        waitForStatus(app, "watching")
        XCTAssertFalse(element(app, "computerImDone").exists)
        shot(app, "computer-handed-back")
    }

    func test4ScrollWheelSendsWheelNotchesWhileControlling() throws {
        let app = signedInApp()
        openComputer(app)
        waitForStatus(app, "watching")
        element(app, "computerTakeControl").hit()
        waitForStatus(app, "controlling")
        let mark = try inputLog().count
        element(app, "computerSurface").scroll(byDeltaX: 0, deltaY: -200)
        try waitForInput(after: mark, containing: "pointer buttons=16", "wheel down notch")
        shot(app, "computer-scrolled")
        element(app, "computerImDone").hit()
        waitForStatus(app, "watching")
    }

    func test5OptionScrollZoomsAndDragPansWhenZoomedIn() throws {
        let app = signedInApp()
        openComputer(app)
        waitForStatus(app, "watching")
        let surface = element(app, "computerSurface")
        shot(app, "computer-before-zoom")
        XCUIElement.perform(withKeyModifiers: .option) { surface.scroll(byDeltaX: 0, deltaY: 400) }
        Thread.sleep(forTimeInterval: 1)
        shot(app, "computer-zoomed")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
            .click(forDuration: 0.1, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)))
        Thread.sleep(forTimeInterval: 1)
        shot(app, "computer-zoomed-panned")
    }
    #endif

    func test6HelpSheetListsTheGesturesAndCloses() throws {
        let app = signedInApp()
        openComputer(app)
        element(app, "computerHelpButton").hit()
        waitFor(element(app, "computerHelp"), timeout: 10, "help sheet")
        for topic in ["takeControl", "scroll", "clickAndDrag", "rightClick", "zoom"] {
            waitFor(element(app, "computerHelpRow-\(topic)"), timeout: 5, "help row \(topic)")
        }
        shot(app, "computer-help")
        element(app, "computerHelp-close").hit()
        waitGone(element(app, "computerHelp"), timeout: 10, "help sheet")
    }

    func test7ComputerUnavailableWhenNoScreenIsRunning() throws {
        let app = signedInApp()
        openComputer(app, Self.primarySlug)
        waitFor(element(app, "computerFailureMessage"), timeout: 30, "unavailable message")
        shot(app, "computer-unavailable")
    }
}
