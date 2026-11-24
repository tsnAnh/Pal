import XCTest

@MainActor
final class HeldDraftApprovalsE2ETests: BotProfileTestCase {
    private let fixtureBot = BotProfileTestCase.otherSlug

    private func approvalsApp() -> XCUIApplication {
        signedInApp(extraArguments: ["-hermes-test-held-drafts", fixtureBot])
    }

    private func openApprovals(_ app: XCUIApplication) {
        #if os(macOS)
        let row = app.buttons["approvalsRow"]
        waitFor(row, timeout: 30, "the Approvals row in the sidebar")
        row.hit()
        waitFor(element(app, "approvalsPanel"), timeout: 20, "the Approvals panel")
        #else
        openProfile(app, fixtureBot)
        let row = app.buttons["profileApprovalsRow"]
        waitFor(row, timeout: 20, "the Approvals row on the bot screen")
        row.hit()
        #endif
        waitFor(element(app, "approvalsScreen"), timeout: 20, "the Approvals list")
    }

    private func draftRow(_ app: XCUIApplication, _ recipient: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "approvalRow-", recipient)).firstMatch
    }

    private func open(_ app: XCUIApplication, _ recipient: String) {
        let row = draftRow(app, recipient)
        waitFor(row, timeout: 20, "the \(recipient) row")
        row.hit()
        waitFor(element(app, "heldDraftSheet"), timeout: 20, "the draft sheet")
    }

    func test1ListShowsEveryWaitingMessageAndTheSheetShowsTheExactTextBeforeAnyChoice() {
        let app = approvalsApp()
        openApprovals(app)
        shot(app, "approvals-list")
        waitFor(draftRow(app, "Sam"), timeout: 20, "Sam")
        waitFor(draftRow(app, "Dana"), timeout: 20, "Dana")
        open(app, "Dana")
        let bubble = element(app, "heldDraftBubble")
        XCTAssertTrue(bubble.label.contains("Lunch at noon?"), "the whole text is in the bubble")
        XCTAssertTrue(bubble.label.contains("I booked the corner table."), "the second line is not cut")
        XCTAssertTrue(app.staticTexts["Send this message?"].exists)
        XCTAssertTrue(app.staticTexts["Nothing is sent until you choose Send."].exists)
        XCTAssertTrue(app.buttons["heldDraftSend"].exists && app.buttons["heldDraftEdit"].exists && app.buttons["heldDraftCancel"].exists)
        shot(app, "approvals-sheet-waiting")
    }

    func test2EditBackSendsNothingThenSendEditedSendsOnce() {
        let app = approvalsApp()
        openApprovals(app)
        open(app, "Sam")
        app.buttons["heldDraftEdit"].hit()
        waitFor(app.staticTexts["Edit before sending"], timeout: 10, "the editor")
        XCTAssertTrue(app.staticTexts["Only the text changes, not who gets it."].exists)
        shot(app, "approvals-sheet-editing")
        app.buttons["heldDraftBack"].hit()
        waitFor(app.staticTexts["Send this message?"], timeout: 10, "Back returns to the question")
        app.buttons["heldDraftEdit"].hit()
        let field = element(app, "heldDraftEditField")
        waitFor(field, timeout: 10, "the edit field")
        field.hit()
        app.typeText(" At 6.")
        app.buttons["heldDraftSendEdited"].hit()
        let status = element(app, "heldDraftStatus")
        waitFor(status, timeout: 20, "the sent line")
        XCTAssertTrue(status.label.hasPrefix("Sent once"), status.label)
        XCTAssertTrue(app.staticTexts["Telegram confirmed it. It cannot be sent again."].exists)
        XCTAssertFalse(app.buttons["heldDraftSend"].exists, "no second send after it was sent")
        shot(app, "approvals-sheet-sent")
    }

    func test3AFailedSendNamesTheReasonAndSendAgainSucceedsOnce() {
        let app = approvalsApp()
        openApprovals(app)
        open(app, "Dana")
        app.buttons["heldDraftSend"].hit()
        let status = element(app, "heldDraftStatus")
        waitFor(app.buttons["heldDraftSendAgain"], timeout: 20, "Send again after the failure")
        XCTAssertEqual(
            status.label,
            "Not sent. Email said: rate limited. It may or may not have gone out; check Email before sending again."
        )
        shot(app, "approvals-sheet-failed")
        app.buttons["heldDraftSendAgain"].hit()
        waitFor(app.staticTexts["Email confirmed it. It cannot be sent again."], timeout: 20, "sent after Send again")
    }

    func test4CancelNeverSendsAndAnExpiredDraftOnlyOffersDiscard() {
        let app = approvalsApp()
        openApprovals(app)
        open(app, "Sam")
        app.buttons["heldDraftCancel"].hit()
        waitFor(app.staticTexts["Not sent. Cancelled."], timeout: 20, "the cancelled line")
        XCTAssertFalse(app.buttons["heldDraftSend"].exists)
        shot(app, "approvals-sheet-cancelled")
        #if os(macOS)
        app.buttons["approvalDetailBack"].hit()
        #else
        app.buttons["approvalDetail-back"].hit()
        #endif
        open(app, "Lee")
        waitFor(app.staticTexts["This draft waited too long. Ask the bot to write it again."], timeout: 10, "expired line")
        XCTAssertTrue(app.buttons["heldDraftDiscard"].exists)
        XCTAssertFalse(app.buttons["heldDraftSend"].exists)
        shot(app, "approvals-sheet-expired")
    }
}
