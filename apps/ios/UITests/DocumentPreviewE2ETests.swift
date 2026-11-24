import XCTest

@MainActor
final class DocumentPreviewE2ETests: E2ETestCase {
    private static let botSlug = "document-bot"
    private static let pdfName = "Q3 report.pdf"
    private static let textName = "notes.txt"

    override func setUp() async throws {
        let seed = ProcessInfo.processInfo.environment["HERMES_UITEST_SEED"] ?? ""
        try XCTSkipUnless(
            seed == "documents",
            "needs a gateway seeded with --seed documents and HERMES_UITEST_SEED=documents: bot \(Self.botSlug) with an assistant message "
            + "holding MEDIA: Q3 report.pdf (a real multi-page PDF), notes.txt (a few lines of text) and huge.pdf (over the 32 MB thumbnail ceiling)"
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

    func testPDFShowsItsFirstPageAndPageCount() throws {
        let app = openChat()
        let pdf = card(app, named: Self.pdfName)
        reveal(app, pdf, "ready document card for \(Self.pdfName)")
        waitGone(any(app, "chatDocumentLoading"), timeout: 60, "thumbnail finishes loading")
        XCTAssertTrue(pdf.label.hasPrefix("PDF document, \(Self.pdfName)"), "label names kind and file: \(pdf.label)")
        XCTAssertTrue(pdf.label.contains("pages"), "label carries the page count: \(pdf.label)")
    }

    func testTextFileShowsAThumbnailCard() throws {
        let app = openChat()
        let text = card(app, named: Self.textName)
        reveal(app, text, "document card for \(Self.textName)")
        waitGone(any(app, "chatDocumentLoading"), timeout: 60, "document thumbnails finish loading")
        XCTAssertTrue(text.label.hasPrefix("Text file, \(Self.textName)"), "label names kind and file: \(text.label)")
    }

    func testOversizedDocumentOffersADownloadInsteadOfAThumbnail() throws {
        let app = openChat()
        reveal(app, any(app, "chatDocumentTooLarge").firstMatch, "too-large card for huge.pdf")
        waitFor(any(app, "chatDocumentDownload").firstMatch, timeout: 10, "download button on the too-large card")
    }

    #if os(iOS)
    func testTappingACardOpensTheQuickLookSheet() throws {
        let app = openChat()
        let pdf = card(app, named: Self.pdfName)
        reveal(app, pdf, "ready document card for \(Self.pdfName)")
        waitGone(any(app, "chatDocumentLoading"), timeout: 60, "thumbnail finishes loading")
        pdf.tap()
        waitFor(any(app, "filePreview"), timeout: 20, "file preview sheet")
        any(app, "filePreviewClose").tap()
        waitGone(any(app, "filePreview"), timeout: 10, "sheet closes")
    }
    #else
    func testCardMenuListsOpenSaveAndReveal() throws {
        let app = openChat()
        let pdf = card(app, named: Self.pdfName)
        reveal(app, pdf, "ready document card for \(Self.pdfName)")
        waitGone(any(app, "chatDocumentLoading"), timeout: 60, "thumbnail finishes loading")
        pdf.rightClick()
        for item in ["Open", "Save As…", "Reveal in Finder"] {
            waitFor(app.menuItems[item], timeout: 10, "\(item) in the card context menu")
        }
        app.typeKey(.escape, modifierFlags: [])
        waitGone(app.menuItems["Open"], timeout: 5, "context menu dismisses")
    }
    #endif
}
