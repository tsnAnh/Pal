import XCTest

@MainActor
final class FileCardE2ETests: E2ETestCase {
    private static let botSlug = "file-bot"
    private static let archiveName = "logs.zip"
    private static let unknownName = "data.bin"
    private static let modelName = "chair.usdz"

    override func setUp() async throws {
        let seed = ProcessInfo.processInfo.environment["HERMES_UITEST_SEED"] ?? ""
        try XCTSkipUnless(
            seed == "files",
            "needs a gateway seeded with --seed files and HERMES_UITEST_SEED=files: bot \(Self.botSlug) with an assistant message "
            + "holding MEDIA: logs.zip (a few MB), data.bin (any bytes), chair.usdz (a real USDZ model), "
            + "huge.zip (over the 200 MB ceiling) and missing.zip (listed but absent on the bot's computer)"
        )
        try await super.setUp()
    }

    private func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func card(_ app: XCUIApplication, named name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "chatDocumentOpen")
            .matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    }

    private func openChat() -> XCUIApplication {
        let app = launch(extraArguments: ["-hermes-reset-preferences"])
        signInIfNeeded(app)
        openBot(app, Self.botSlug)
        return app
    }

    private func reveal(_ app: XCUIApplication, _ element: XCUIElement, _ message: String) {
        let chat = any(app, "chatScreen")
        for _ in 0..<12 where !element.exists {
            #if os(iOS)
            chat.swipeDown(velocity: .fast)
            #else
            chat.scroll(byDeltaX: 0, deltaY: 600)
            #endif
            _ = element.waitForExistence(timeout: 1)
        }
        waitFor(element, timeout: 10, message)
    }

    func testArchiveShowsAnIconCardWithKindAndSize() throws {
        let app = openChat()
        let archive = card(app, named: Self.archiveName)
        reveal(app, archive, "ready icon card for \(Self.archiveName)")
        waitGone(any(app, "chatDocumentLoading"), timeout: 60, "card finishes loading")
        XCTAssertTrue(archive.label.hasPrefix("Archive, \(Self.archiveName)"), "label names kind and file: \(archive.label)")
    }

    func testUnknownFileShowsAnIconCard() throws {
        let app = openChat()
        let unknown = card(app, named: Self.unknownName)
        reveal(app, unknown, "ready icon card for \(Self.unknownName)")
        XCTAssertTrue(unknown.label.hasPrefix("File, \(Self.unknownName)"), "label names kind and file: \(unknown.label)")
    }

    func testModelShowsAThumbnailOrAnIconCard() throws {
        let app = openChat()
        let model = card(app, named: Self.modelName)
        reveal(app, model, "ready card for \(Self.modelName)")
        waitGone(any(app, "chatDocumentLoading"), timeout: 60, "model thumbnail finishes loading")
        XCTAssertTrue(model.label.hasPrefix("3D model, \(Self.modelName)"), "label names kind and file: \(model.label)")
    }

    func testOversizedArchiveOffersADownload() throws {
        let app = openChat()
        reveal(app, any(app, "chatDocumentTooLarge").firstMatch, "too-large card for huge.zip")
        waitFor(any(app, "chatDocumentDownload").firstMatch, timeout: 10, "download button on the too-large card")
    }

    func testMissingFileShowsItsReasonWithoutRetry() throws {
        let app = openChat()
        reveal(app, any(app, "chatDocumentFailed").firstMatch, "failed card for missing.zip")
        XCTAssertFalse(any(app, "chatDocumentRetry").exists, "a file that is gone is not retryable")
    }

    #if os(iOS)
    func testTappingAnArchiveOpensTheFileSheet() throws {
        let app = openChat()
        let archive = card(app, named: Self.archiveName)
        reveal(app, archive, "ready icon card for \(Self.archiveName)")
        waitGone(any(app, "chatDocumentLoading"), timeout: 60, "card finishes loading")
        archive.tap()
        waitFor(any(app, "filePreview"), timeout: 20, "file preview sheet")
        any(app, "filePreviewClose").tap()
        waitGone(any(app, "filePreview"), timeout: 10, "sheet closes")
    }
    #else
    func testArchiveMenuListsOpenSaveAndReveal() throws {
        let app = openChat()
        let archive = card(app, named: Self.archiveName)
        reveal(app, archive, "ready icon card for \(Self.archiveName)")
        waitGone(any(app, "chatDocumentLoading"), timeout: 60, "card finishes loading")
        archive.rightClick()
        for item in ["Open", "Save As…", "Reveal in Finder"] {
            waitFor(app.menuItems[item], timeout: 10, "\(item) in the card context menu")
        }
        app.typeKey(.escape, modifierFlags: [])
        waitGone(app.menuItems["Open"], timeout: 5, "context menu dismisses")
    }
    #endif
}
