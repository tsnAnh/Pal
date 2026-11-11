import XCTest

@MainActor
final class BotProfileE2ETests: BotProfileTestCase {
    func test1ProfileShowsRoutinesCountComputerStatusAndNotificationsOn() throws {
        let app = signedInApp()
        openProfile(app, Self.primarySlug)
        waitUntil(20, "routines count and computer status") {
            element(app, "profileRoutinesRow").label.contains("2 on") && element(app, "profileComputerRow").label.contains("Unavailable")
        }
        XCTAssertEqual(element(app, "profileAvatar").value as? String, "Primary bot")
        XCTAssertTrue(toggleIsOn(element(app, "profileNotificationsToggle")), "notifications default on")
        shot(app, "profile-primary")
    }

    func test2NotificationsTogglePersistsAcrossReopen() throws {
        let app = signedInApp()
        openProfile(app, Self.otherSlug)
        let toggle = element(app, "profileNotificationsToggle")
        waitFor(toggle, timeout: 10, "notifications toggle")
        XCTAssertTrue(toggleIsOn(toggle))
        toggle.tap()
        waitUntil(10, "toggle off") { !toggleIsOn(toggle) }
        Thread.sleep(forTimeInterval: 1.5)
        goBack(app)
        openProfile(app, Self.otherSlug)
        let reopened = element(app, "profileNotificationsToggle")
        waitFor(reopened, timeout: 10, "reopened toggle")
        waitUntil(15, "persisted off after reopen") { !toggleIsOn(reopened) }
        shot(app, "notifications-off-after-reopen")
        reopened.tap()
        waitUntil(10, "toggle back on") { toggleIsOn(reopened) }
        Thread.sleep(forTimeInterval: 1.5)
        goBack(app)
        openProfile(app, Self.otherSlug)
        waitUntil(15, "restored on after reopen") { toggleIsOn(element(app, "profileNotificationsToggle")) }
    }

    func test3RoutinePauseResumePersists() throws {
        let app = signedInApp()
        openProfile(app, Self.primarySlug)
        element(app, "profileRoutinesRow").tap()
        waitFor(element(app, "routinesCard"), timeout: 30, "routines list")
        let toggle = firstRoutineToggle(app)
        waitFor(toggle, timeout: 10, "routine toggle")
        XCTAssertTrue(toggleIsOn(toggle))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "(")).firstMatch.exists, "schedule caption with zone")
        toggle.tap()
        waitUntil(10, "paused") { !toggleIsOn(toggle) }
        Thread.sleep(forTimeInterval: 1.5)
        goBack(app)
        waitUntil(20, "profile counts one routine on") { element(app, "profileRoutinesRow").label.contains("1 on") }
        element(app, "profileRoutinesRow").tap()
        let reopened = firstRoutineToggle(app)
        waitFor(reopened, timeout: 20, "reopened routine toggle")
        waitUntil(15, "pause persisted") { !toggleIsOn(reopened) }
        shot(app, "routine-paused")
        reopened.tap()
        waitUntil(10, "resumed") { toggleIsOn(reopened) }
        Thread.sleep(forTimeInterval: 1.5)
        goBack(app)
        waitUntil(20, "profile counts two routines on again") { element(app, "profileRoutinesRow").label.contains("2 on") }
    }

    func test4CreateAndDeleteRoutine() throws {
        let app = signedInApp()
        openProfile(app, Self.primarySlug)
        element(app, "profileRoutinesRow").tap()
        waitFor(element(app, "routinesCard"), timeout: 30, "routines list")
        element(app, "routinesNewButton").tap()
        waitFor(element(app, "newRoutineSheet"), timeout: 10, "new routine sheet")
        let title = app.textFields["newRoutineTitle"]
        title.tap()
        title.typeText("E2E nightly check")
        let prompt = app.textFields["newRoutinePrompt"]
        prompt.tap()
        prompt.typeText("Say hello")
        let schedule = app.textFields["newRoutineSchedule"]
        schedule.tap()
        schedule.typeText("every day at 7am")
        waitFor(element(app, "newRoutineAcceptedAs"), timeout: 15, "accepted as line")
        shot(app, "new-routine-accepted")
        element(app, "newRoutineSave").tap()
        let created = app.staticTexts["E2E nightly check"].firstMatch
        waitFor(created, timeout: 20, "new routine row")
        created.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        waitFor(delete, timeout: 10, "swipe delete action")
        shot(app, "routine-swiped")
        delete.tap()
        waitFor(app.staticTexts["Delete this routine?"], timeout: 10, "delete confirmation title")
        let confirm = app.buttons["Delete"].firstMatch
        waitFor(confirm, timeout: 10, "delete confirmation")
        shot(app, "routine-delete-confirm")
        confirm.tap()
        waitGone(created, timeout: 20, "deleted routine")
    }

    func test5ReplacePrimaryMovesTheStarAndRestores() throws {
        let app = signedInApp()
        openProfile(app, Self.otherSlug)
        XCTAssertNotEqual(element(app, "profileAvatar").value as? String, "Primary bot")
        element(app, "profileMoreButton").tap()
        waitFor(app.buttons["Replace Primary Bot…"], timeout: 10, "replace primary item")
        app.buttons["Replace Primary Bot…"].tap()
        waitFor(app.buttons.matching(NSPredicate(format: "label == %@", "Replace")).firstMatch, timeout: 10, "confirmation")
        shot(app, "replace-primary-confirm")
        confirmReplace(app)
        waitUntil(20, "star moved to this bot") { element(app, "profileAvatar").value as? String == "Primary bot" }
        shot(app, "star-moved")
        goBack(app)
        openProfile(app, Self.primarySlug)
        waitUntil(20, "previous primary lost the star") { element(app, "profileAvatar").value as? String != "Primary bot" }
        element(app, "profileMoreButton").tap()
        waitFor(app.buttons["Replace Primary Bot…"], timeout: 10, "replace primary item on the old primary")
        app.buttons["Replace Primary Bot…"].tap()
        confirmReplace(app)
        waitUntil(20, "star restored") { element(app, "profileAvatar").value as? String == "Primary bot" }
    }

    func test6CopyIDShowsToastAndFillsPasteboard() throws {
        let app = signedInApp()
        openProfile(app, Self.otherSlug)
        element(app, "profileMoreButton").tap()
        waitFor(app.buttons["Copy ID"], timeout: 10, "copy item")
        app.buttons["Copy ID"].tap()
        shot(app, "copy-id-toast")
        element(app, "profileEditButton").tap()
        let name = app.textFields["editBotName"]
        waitFor(name, timeout: 10, "edit name field")
        name.tap()
        name.press(forDuration: 1.0)
        let paste = app.menuItems["Paste"]
        waitFor(paste, timeout: 10, "paste menu item")
        paste.tap()
        let pasted = NSPredicate(format: "value CONTAINS %@", Self.otherSlug)
        waitFor(app.textFields.matching(pasted).firstMatch, timeout: 10, "pasteboard holds the bot id")
    }

    func test7ShareTemplateOffersAHermesbotFile() throws {
        let app = signedInApp()
        openProfile(app, Self.otherSlug)
        element(app, "profileShareButton").tap()
        let sheet = app.otherElements["ActivityListView"]
        waitFor(sheet, timeout: 30, "share sheet")
        Thread.sleep(forTimeInterval: 1.5)
        shot(app, "share-template-sheet")
        let named = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", Self.otherSlug, Self.otherSlug)).firstMatch
        waitFor(named, timeout: 10, "template file name in the share sheet")
        let close = app.buttons["Close"]
        if close.exists { close.tap() } else { app.swipeDown() }
    }

    func test8LibraryListsSectionsAndOpensLinkAndMedia() throws {
        let app = signedInApp()
        openProfile(app, Self.primarySlug)
        element(app, "profileLibraryRow").tap()
        waitFor(element(app, "libraryCard-thisWeek"), timeout: 30, "this week section")
        XCTAssertTrue(element(app, "libraryCard-older").waitForExistence(timeout: 15), "older section")
        shot(app, "library-all")
        element(app, "libraryFilter-links").tap()
        let link = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value == %@", "libraryRow-", "link")).firstMatch
        waitFor(link, timeout: 20, "link row")
        link.tap()
        let done = safariDone()
        waitFor(done, timeout: 30, "in-app browser")
        shot(app, "library-link-safari")
        done.tap()
        waitGone(done, timeout: 10, "browser closed")
        element(app, "libraryFilter-media").tap()
        let media = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value == %@", "libraryRow-", "media")).firstMatch
        waitFor(media, timeout: 20, "media row")
        media.tap()
        let preview = app.otherElements["QLPreviewControllerView"].exists ? app.otherElements["QLPreviewControllerView"] : app.navigationBars["library-sample.png"]
        waitFor(preview, timeout: 20, "full-screen preview")
        shot(app, "library-media-preview")
    }

    func test9aSlackSuggestionIsHiddenWhenSlackIsNotConnected() throws {
        let app = signedInApp()
        openProfile(app, Self.primarySlug)
        waitFor(element(app, "profileComputerRow"), timeout: 20, "profile rows")
        XCTAssertFalse(element(app, "profileSlackRow").waitForExistence(timeout: 3), "no Add to Slack while Slack is not connected")
    }

    func test9SlackScreenTokenEntryRequiresWellFormedTokens() throws {
        let app = signedInApp(connectedServices: ["slack"])
        openProfile(app, Self.primarySlug)
        element(app, "profileSlackRow").tap()
        let connect = element(app, "slackConnectButton")
        waitFor(connect, timeout: 30, "connect button")
        XCTAssertTrue(element(app, "slackBody").label.contains("It'll respond with the same plugins, context, and memories it uses here."))
        shot(app, "slack-ready")
        connect.tap()
        let opened = element(app, "externalLinkProbe")
        waitUntil(30, "slack create page handed to the system browser opener") { opened.value as? String == "1" }
        XCTAssertTrue(opened.label.hasPrefix("https://api.slack.com/apps"), "opened \(opened.label)")
        waitFor(element(app, "slackTokenSheet"), timeout: 15, "token sheet")
        let submit = element(app, "slackTokenSubmit")
        XCTAssertFalse(submit.isEnabled)
        let bot = app.secureTextFields["slackBotToken"]
        bot.tap()
        bot.typeText("xoxp-not-a-bot-token")
        let appToken = app.secureTextFields["slackAppToken"]
        appToken.tap()
        appToken.typeText("xapp-1-fake")
        XCTAssertFalse(submit.isEnabled, "wrong prefix keeps connect disabled")
        shot(app, "slack-tokens-invalid")
    }

    func test9bTelegramScreenTokenEntryRequiresWellFormedToken() throws {
        let app = signedInApp()
        openProfile(app, Self.primarySlug)
        element(app, "profileTelegramRow").tap()
        let connect = element(app, "telegramConnectButton")
        waitFor(connect, timeout: 30, "connect button")
        shot(app, "telegram-ready")
        connect.tap()
        waitFor(element(app, "telegramTokenSheet"), timeout: 15, "token sheet")
        let submit = element(app, "telegramTokenSubmit")
        XCTAssertFalse(submit.isEnabled)
        let token = app.secureTextFields["telegramBotToken"]
        token.tap()
        token.typeText("not-a-botfather-token")
        XCTAssertFalse(submit.isEnabled, "a malformed token keeps connect disabled")
        shot(app, "telegram-token-invalid")
    }
}
