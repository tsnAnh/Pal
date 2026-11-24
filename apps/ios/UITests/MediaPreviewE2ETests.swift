import XCTest

@MainActor
final class MediaPreviewE2ETests: E2ETestCase {
    private static let botSlug = "media-bot"
    private static let audioName = "note.m4a"
    private static let videoName = "clip.mp4"

    override func setUp() async throws {
        let seed = ProcessInfo.processInfo.environment["HERMES_UITEST_SEED"] ?? ""
        try XCTSkipUnless(
            seed == "media",
            "needs a gateway seeded with --seed media and HERMES_UITEST_SEED=media: bot \(Self.botSlug) with an assistant message "
            + "holding MEDIA: clip.mp4 (small video), note.m4a (audio) and huge.mp4 (over the 200 MB ceiling), "
            + "then a later message with three MEDIA: videos for the grid"
        )
        try await super.setUp()
    }

    private func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func all(_ app: XCUIApplication, _ identifier: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: identifier)
    }

    private func openChat() -> XCUIApplication {
        let app = launch(extraArguments: ["-hermes-reset-preferences"])
        signInIfNeeded(app)
        openBot(app, Self.botSlug)
        return app
    }

    private func scrollUp(_ app: XCUIApplication) {
        let chat = any(app, "chatScreen")
        #if os(iOS)
        chat.swipeDown(velocity: .fast)
        #else
        chat.scroll(byDeltaX: 0, deltaY: 600)
        #endif
    }

    private func reveal(_ app: XCUIApplication, _ element: XCUIElement, _ message: String) {
        for _ in 0..<12 where !element.exists {
            scrollUp(app)
            _ = element.waitForExistence(timeout: 1)
        }
        waitFor(element, timeout: 10, message)
    }

    private func videoTile(_ app: XCUIApplication) -> XCUIElement {
        all(app, "chatMediaTile").matching(NSPredicate(format: "label CONTAINS %@", Self.videoName)).firstMatch
    }

    private func waitForLabel(_ element: XCUIElement, equals label: String, timeout: TimeInterval = 15) {
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [match], timeout: timeout), .completed, "label of \(element) never became \(label)")
    }

    private func openVideoTile(_ app: XCUIApplication) -> XCUIElement {
        let tile = videoTile(app)
        reveal(app, tile, "ready video poster tile for \(Self.videoName)")
        waitGone(any(app, "chatMediaLoading"), timeout: 60, "poster loading placeholders settle")
        return tile
    }

    func testVideoTileShowsADurationCapsule() throws {
        let app = openChat()
        _ = openVideoTile(app)
        waitFor(any(app, "chatMediaDuration").firstMatch, timeout: 10, "duration capsule on the video poster")
    }

    func testAudioBarPlaysAndPauses() throws {
        let app = openChat()
        reveal(app, any(app, "chatAudioBar"), "audio bar for \(Self.audioName)")
        let play = any(app, "chatAudioPlay")
        waitFor(play, timeout: 20, "play control in the audio bar")
        waitFor(any(app, "chatAudioScrubber"), timeout: 10, "scrubber in the audio bar")
        XCTAssertEqual(play.label, "Play \(Self.audioName)")
        play.hit()
        waitForLabel(play, equals: "Pause \(Self.audioName)")
        play.hit()
        waitForLabel(play, equals: "Play \(Self.audioName)")
    }

    func testOversizedVideoOffersADownloadInsteadOfAPreview() throws {
        let app = openChat()
        reveal(app, any(app, "chatMediaTooLarge").firstMatch, "too-large card for huge.mp4")
        waitFor(any(app, "chatMediaDownload").firstMatch, timeout: 10, "download button on the too-large card")
    }

    func testThreeVideosShareOneGrid() throws {
        let app = openChat()
        let grid = any(app, "chatMediaGrid")
        reveal(app, grid, "media grid for the three-video message")
        XCTAssertEqual(all(app, "chatMediaGrid").count, 1, "the three videos render in one grid")
        waitGone(any(app, "chatMediaLoading"), timeout: 60, "grid posters finish loading")
        XCTAssertEqual(grid.descendants(matching: .any).matching(identifier: "chatMediaTile").count, 3, "three poster tiles inside the grid")
    }

    #if os(iOS)
    func testVideoTileOpensThePlayerCoverAndCloses() throws {
        let app = openChat()
        openVideoTile(app).tap()
        waitFor(any(app, "mediaViewer"), timeout: 20, "media viewer cover")
        waitFor(any(app, "mediaViewerPlayer"), timeout: 30, "player inside the viewer")
        any(app, "mediaViewerClose").tap()
        waitGone(any(app, "mediaViewer"), timeout: 10, "viewer closes")
    }
    #else
    func testVideoTileMenuListsOpenSaveAndReveal() throws {
        let app = openChat()
        let tile = openVideoTile(app)
        tile.rightClick()
        for item in ["Open", "Save As…", "Reveal in Finder"] {
            waitFor(app.menuItems[item], timeout: 10, "\(item) in the tile context menu")
        }
        app.typeKey(.escape, modifierFlags: [])
        waitGone(app.menuItems["Open"], timeout: 5, "context menu dismisses")
    }

    func testViewerAcceptsKeysAndEscapeClosesIt() throws {
        let app = openChat()
        openVideoTile(app).click()
        waitFor(any(app, "mediaViewer"), timeout: 20, "media viewer")
        waitFor(any(app, "mediaViewerPlayer"), timeout: 30, "player inside the viewer")
        waitFor(any(app, "imageViewerTitle"), timeout: 10, "viewer title")
        app.typeKey(.space, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertTrue(any(app, "mediaViewer").exists, "space and arrow keys keep the viewer open")
        app.typeKey(.escape, modifierFlags: [])
        waitGone(any(app, "mediaViewer"), timeout: 10, "escape closes the viewer")
    }

    func testViewerStageFollowsAResizedWindow() throws {
        let app = openChat()
        openVideoTile(app).click()
        waitFor(any(app, "mediaViewerPlayer"), timeout: 30, "player inside the viewer")
        let window = app.windows.firstMatch
        let narrower = window.frame.width - 200
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -1, dy: 0))
        edge.press(forDuration: 0.3, thenDragTo: edge.withOffset(CGVector(dx: -200, dy: 0)))
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, abs(window.frame.width - narrower) > 8 { Thread.sleep(forTimeInterval: 0.2) }
        Thread.sleep(forTimeInterval: 0.6)
        let stage = any(app, "mediaViewerPlayer").frame
        XCTAssertGreaterThanOrEqual(stage.minX, window.frame.minX - 2, "player starts inside the resized window")
        XCTAssertLessThanOrEqual(stage.maxX, window.frame.maxX + 2, "player ends inside the resized window")
        XCTAssertTrue(any(app, "imageViewerClose").isHittable, "close stays reachable after the resize")
    }

    func testViewerKeepsKeyboardFocusForCopyAndSave() throws {
        let app = openChat()
        openVideoTile(app).click()
        waitFor(any(app, "mediaViewerPlayer"), timeout: 30, "player inside the viewer")
        app.typeKey("c", modifierFlags: .command)
        XCTAssertTrue(any(app, "mediaViewer").exists, "copy keeps the viewer open")
        XCTAssertTrue(any(app, "imageViewerDownload").isEnabled, "Save As is available once the file is loaded")
    }

    func testViewerCloseButtonClosesIt() throws {
        let app = openChat()
        openVideoTile(app).click()
        waitFor(any(app, "mediaViewer"), timeout: 20, "media viewer")
        any(app, "imageViewerClose").click()
        waitGone(any(app, "mediaViewer"), timeout: 10, "viewer closes")
    }
    #endif
}
