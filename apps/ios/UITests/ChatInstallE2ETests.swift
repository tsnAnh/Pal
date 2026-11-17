import XCTest
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class ChatInstallE2ETests: BotProfileTestCase {
    private static let scripted = ["-hermes-test-chat-install"]
    private static let filler = String(repeating: "TEST", count: 4)

    private func copyToClipboard(_ parts: [String], separator: String) {
        let text = parts.joined(separator: separator)
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    private func openWizard(_ app: XCUIApplication) {
        openProfile(app, Self.primarySlug)
        element(app, "profileSlackRow").tap()
        waitFor(element(app, "chatInstallScreen"), timeout: 30, "wizard screen")
    }

    private func primary(_ app: XCUIApplication, _ label: String) {
        let button = element(app, "chatInstallPrimary")
        waitUntil(20, "primary reads \(label)") { button.exists && button.label.contains(label) && button.isEnabled }
        button.hit()
    }

    private func assertOneWayOut(_ app: XCUIApplication, _ screen: String) {
        #if os(iOS)
        let bar = app.navigationBars.firstMatch
        if bar.exists {
            XCTAssertLessThanOrEqual(bar.buttons.count, 1, "\(screen) has one back or close control")
        }
        #endif
        XCTAssertFalse(app.buttons["xmark"].exists, "\(screen) draws no custom close")
        XCTAssertFalse(app.buttons["chevron.left"].exists, "\(screen) draws no custom back")
    }

    func testWizardWalksFromNotStartedToReadyWithResumeAndPrivateInvite() throws {
        var app = signedInApp(connectedServices: ["slack"], extraArguments: Self.scripted + ["-hermes-test-chat-install-reset"])
        openWizard(app)
        waitFor(element(app, "chatInstallIntroSteps"), timeout: 20, "intro steps")
        XCTAssertTrue(element(app, "chatInstallPreview").exists, "bot preview")
        XCTAssertTrue(element(app, "chatInstallAdvanced").exists, "advanced paste tokens fallback")
        assertOneWayOut(app, "intro")
        shot(app, "chat-install-intro")
        primary(app, "Create")

        waitFor(element(app, "chatInstallCredentialSteps"), timeout: 20, "credential steps")
        element(app, "chatInstallOpenSlackApps").hit()
        let opened = element(app, "externalLinkProbe")
        waitUntil(20, "slack apps page opened") { opened.label.hasPrefix("https://api.slack.com/apps") }
        assertOneWayOut(app, "credential")
        copyToClipboard(["xoxe.xoxp", "1", Self.filler], separator: "-")
        element(app, "chatInstallPasteCredential").hit()
        waitUntil(10, "access token slot filled") { element(app, "chatInstallAccessSlot").value as? String == "Added" }
        copyToClipboard(["xoxe", "1", Self.filler], separator: "-")
        element(app, "chatInstallPasteCredential").hit()
        waitUntil(10, "refresh token slot filled") { element(app, "chatInstallRefreshSlot").value as? String == "Added" }
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", Self.filler)).firstMatch.exists, "no token text on screen")
        shot(app, "chat-install-credential")
        primary(app, "Use these tokens")

        waitFor(element(app, "chatInstallCheck-createApp"), timeout: 20, "checklist")
        waitFor(element(app, "chatInstallTask-set_icon"), timeout: 20, "avatar task after app created event")
        XCTAssertEqual(element(app, "chatInstallCheck-workspace").value as? String, "Done")
        XCTAssertTrue(element(app, "chatInstallSaveAvatar").exists)
        assertOneWayOut(app, "avatar task")
        shot(app, "chat-install-avatar")
        primary(app, "Done")
        waitFor(element(app, "chatInstallTask-app_level_credential"), timeout: 20, "app key task")

        app.terminate()
        app = signedInApp(connectedServices: ["slack"], extraArguments: Self.scripted)
        openWizard(app)
        waitFor(element(app, "chatInstallTask-app_level_credential"), timeout: 20, "resumed on app key task")
        XCTAssertEqual(element(app, "chatInstallCheck-set_icon").value as? String, "Done", "avatar step stays done")
        copyToClipboard(["xapp", "1", Self.filler], separator: "-")
        element(app, "chatInstallPasteAppKey").hit()
        waitUntil(10, "app key slot filled") { element(app, "chatInstallAppKeySlot").value as? String == "Added" }
        shot(app, "chat-install-app-key")
        primary(app, "Done")

        waitFor(element(app, "chatInstallAllowBody"), timeout: 20, "allow step")
        XCTAssertTrue(element(app, "chatInstall-CopyAdminMessage").exists, "admin message")
        assertOneWayOut(app, "allow")
        shot(app, "chat-install-allow")
        primary(app, "Add to Slack")
        waitUntil(20, "authorize link opened in the system browser") { opened.label.contains("oauth/v2/authorize") }
        element(app, "chatInstall-CheckAgain").hit()

        waitFor(element(app, "chatInstallReady"), timeout: 30, "ready")
        waitFor(element(app, "chatInstallJoin-C1"), timeout: 20, "public channel row")
        element(app, "chatInstallJoin-C1").hit()
        waitFor(element(app, "chatInstallSpaceLive-C1"), timeout: 20, "public channel live")
        element(app, "chatInstallJoin-G1").hit()
        waitFor(element(app, "chatInstallSpaceWaiting-G1"), timeout: 20, "private channel waits for invite")
        XCTAssertTrue(element(app, "chatInstallCopyInvite-G1").exists)
        XCTAssertTrue(element(app, "chatInstallOpenChannel-G1").exists)
        shot(app, "chat-install-private-invite")
        element(app, "chatInstallRefreshChannels").hit()
        waitFor(element(app, "chatInstallSpaceLive-G1"), timeout: 20, "private channel live after invite")
        assertOneWayOut(app, "ready")
        shot(app, "chat-install-ready")

        element(app, "chatInstallDisconnect").hit()
        let confirm = element(app, "chatInstallDisconnectConfirm")
        waitFor(confirm, timeout: 10, "disconnect confirmation")
        confirm.hit()
        waitFor(element(app, "chatInstallIntroSteps"), timeout: 20, "back to intro after disconnect")
    }
}
