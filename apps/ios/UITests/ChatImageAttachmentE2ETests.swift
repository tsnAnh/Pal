import XCTest

@MainActor
final class ChatImageAttachmentE2ETests: E2ETestCase {
    override func setUp() async throws {
        let seed = ProcessInfo.processInfo.environment["HERMES_UITEST_SEED"] ?? ""
        try XCTSkipUnless(seed == "parity", "needs a gateway started with --seed parity and HERMES_UITEST_SEED=parity")
        try await super.setUp()
    }

    private func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func openChat() -> XCUIApplication {
        let app = launch(extraArguments: ["-hermes-reset-preferences"])
        signInIfNeeded(app)
        openBot(app, "cho-ua")
        return app
    }

    #if os(iOS)
    func testSentPhotoShowsInTheBubbleAndEnlarges() throws {
        let app = openChat()
        app.buttons["attachButton"].tap()
        waitFor(app.buttons["attachPhotos"], timeout: 10, "attach menu")
        app.buttons["attachPhotos"].tap()
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH %@", "Photo,")).firstMatch
        waitFor(photo, timeout: 30, "photo library picker")
        photo.tap()
        let add = app.buttons["Add"]
        if add.waitForExistence(timeout: 5) { add.tap() }
        waitFor(any(app, "attachmentThumbnail"), timeout: 20, "thumbnail in the tray")
        waitFor(any(app, "removeAttachment"), timeout: 5, "remove button in the tray")
        waitGone(any(app, "attachmentUploading"), timeout: 60, "upload finishes")
        app.buttons["sendButton"].tap()
        let sent = any(app, "chatImage")
        waitFor(sent, timeout: 60, "sent image rendered in the bubble")
        sent.tap()
        waitFor(any(app, "imageViewerImage"), timeout: 30, "enlarged image")
        any(app, "imageViewerClose").tap()
        waitGone(any(app, "imageViewer"), timeout: 10, "viewer closes")
    }
    #else
    func testPastedImageShowsAThumbnailThatCanBeRemoved() throws {
        let app = openChat()
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        let field = any(app, "composerField")
        field.click()
        field.typeKey("v", modifierFlags: .command)
        waitFor(any(app, "attachmentThumbnail"), timeout: 20, "thumbnail for the pasted image")
        let remove = any(app, "removeAttachment")
        waitFor(remove, timeout: 5, "remove button")
        remove.click()
        waitGone(any(app, "attachmentChip"), timeout: 10, "chip removed")
    }
    #endif
}
