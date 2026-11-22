import PalDesign
import XCTest

@MainActor
final class SlackMemberShots: BotProfileTestCase {
    private static let scripted = ["-hermes-test-chat-install", "-hermes-test-chat-install-ready"]

    private func launchReady(_ appearance: AppearanceMode) -> XCUIApplication {
        signedInApp(appearance: appearance, connectedServices: [], extraArguments: Self.scripted)
    }

    private func tag(_ appearance: AppearanceMode) -> String { appearance == .dark ? "dark" : "light" }

    private func tap(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval = 20) {
        let target = element(app, identifier)
        waitFor(target, timeout: timeout, identifier)
        target.hit()
    }

    private func settle() { Thread.sleep(forTimeInterval: 1.2) }

    func testProfileRowAndSettingsGroups() throws {
        for appearance in [AppearanceMode.light, .dark] {
            let name = tag(appearance)
            let app = launchReady(appearance)
            openProfile(app, Self.primarySlug)
            waitUntil(30, "profile Slack row reads live") { element(app, "profileSlackLive").exists }
            settle()
            shot(app, "slack-profile-row-\(name)")
            tap(app, "profileSlackRow")
            waitFor(element(app, "slackAudience"), timeout: 30, "settings groups")
            settle()
            shot(app, "slack-settings-only-me-\(name)")
            tap(app, "slackAudienceWorkspace")
            waitFor(element(app, "slackAudienceGuests"), timeout: 20, "guests switch")
            settle()
            shot(app, "slack-settings-workspace-\(name)")
            tap(app, "slackAudienceListed")
            waitFor(element(app, "slackAudienceEmpty"), timeout: 20, "nobody picked")
            settle()
            shot(app, "slack-settings-nobody-picked-\(name)")
            app.terminate()
        }
    }

    func testPeoplePickerAndReports() throws {
        for appearance in [AppearanceMode.light, .dark] {
            let name = tag(appearance)
            let app = launchReady(appearance)
            openProfile(app, Self.primarySlug)
            tap(app, "profileSlackRow")
            waitFor(element(app, "slackAudience"), timeout: 30, "settings groups")
            tap(app, "slackAudienceListed")
            tap(app, "slackAudienceAdd")
            waitFor(element(app, "slackPeopleList"), timeout: 30, "people")
            settle()
            shot(app, "slack-people-\(name)")
            tap(app, "slackPerson-U1")
            tap(app, "slackPerson-U2")
            tap(app, "slackPerson-U3")
            settle()
            shot(app, "slack-people-picked-\(name)")
            let search = element(app, "slackPeopleSearch")
            search.hit()
            search.typeText("zhang")
            waitFor(element(app, "slackPeopleEmpty"), timeout: 20, "empty search")
            settle()
            shot(app, "slack-people-empty-\(name)")
            for _ in 0..<5 { search.typeText(XCUIKeyboardKey.delete.rawValue) }
            waitFor(element(app, "slackPeopleList"), timeout: 20, "list returns")
            tap(app, "slackPeopleDone")
            waitFor(element(app, "slackAudienceMember-U1"), timeout: 20, "chips")
            settle()
            shot(app, "slack-settings-specific-\(name)")
            tap(app, "slackReportChannelMenu")
            waitFor(element(app, "slackReportChannel-C1"), timeout: 20, "report menu")
            settle()
            shot(app, "slack-report-menu-\(name)")
            tap(app, "slackReportChannel-C1")
            settle()
            shot(app, "slack-report-channel-\(name)")
            app.terminate()
        }
    }

    func testChannelsLeave() throws {
        for appearance in [AppearanceMode.light, .dark] {
            let name = tag(appearance)
            let app = launchReady(appearance)
            openProfile(app, Self.primarySlug)
            tap(app, "profileSlackRow")
            tap(app, "slackChannelsChange")
            waitFor(element(app, "slackChannelsJoined"), timeout: 30, "joined channels")
            settle()
            shot(app, "slack-channels-\(name)")
            #if os(macOS)
            tap(app, "slackChannelMenu-C2")
            waitFor(element(app, "slackChannelLeave-C2"), timeout: 10, "leave item")
            shot(app, "slack-channels-menu-\(name)")
            tap(app, "slackChannelLeave-C2")
            #else
            element(app, "slackChannelSwipe-C2").swipeLeft()
            settle()
            shot(app, "slack-channels-swipe-\(name)")
            let leave = app.buttons["Leave"].firstMatch
            waitFor(leave, timeout: 10, "leave action")
            leave.hit()
            #endif
            waitFor(app.buttons.matching(identifier: "slackLeaveConfirm").firstMatch, timeout: 10, "leave confirmation")
            settle()
            shot(app, "slack-channels-leave-confirm-\(name)")
            let confirm = app.buttons.matching(identifier: "slackLeaveConfirm").firstMatch
            waitFor(confirm, timeout: 10, "confirm button")
            confirm.hit()
            waitUntil(20, "channel is gone from the joined list") { !element(app, "slackChannel-C2").label.contains("Live") }
            settle()
            shot(app, "slack-channels-after-leave-\(name)")
            app.terminate()
        }
    }

    func testApprovalCard() throws {
        for appearance in [AppearanceMode.light, .dark] {
            let name = tag(appearance)
            let app = launchReady(appearance)
            #if os(iOS)
            tap(app, "botRow-\(Self.primarySlug)")
            #else
            openProfile(app, Self.primarySlug)
            #endif
            let approve = element(app, "deskApprove-D1")
            waitFor(approve, timeout: 40, "approval card")
            settle()
            shot(app, "slack-approval-pending-\(name)")
            approve.hit()
            waitFor(element(app, "deskCardResolved-D1"), timeout: 20, "allowed state")
            settle()
            shot(app, "slack-approval-allowed-\(name)")
            app.terminate()
        }
    }
}
