import Foundation
import PalConnect
import PalProtocol
import Testing

@Suite("Slack setup plan")
struct SlackSetupPlanTests {
    private func plan(_ state: ChatSetupStateWire?, guided: [String] = []) throws -> SlackSetupPlan {
        SlackSetupPlan(displayName: "Pal", provider: try chatProvider(guided: guided), state: state)
    }

    private func engine(_ plan: SlackSetupPlan) throws -> StepFlowEngine {
        let resume = StepFlowProgress(flowID: SlackSetupPlan.flowID, stepID: plan.currentID)
        return try #require(StepFlowEngine(flowID: SlackSetupPlan.flowID, steps: plan.steps, resume: resume))
    }

    @Test func everyGatewayStepLandsOnItsScreen() throws {
        let allow: [String: Any?] = ["kind": "open_link", "action_id": "allow", "link": "https://slack.com/oauth/v2/authorize?client_id=1"]
        let cases: [(ChatSetupStateWire?, String)] = [
            (nil, SlackSetupPlan.introID),
            (try chatState("not_started", 0), SlackSetupPlan.introID),
            (try chatState("revoked", 1), SlackSetupPlan.introID),
            (try chatState("needs_credential", 2), SlackSetupPlan.credentialID),
            (try chatState("creating_app", 3), SlackSetupPlan.creatingID),
            (try chatState("needs_allow", 4, action: allow), SlackSetupPlan.allowID),
            (try chatState("installing", 5), SlackSetupPlan.installingID),
            (try chatState("needs_owner", 6), SlackSetupPlan.ownerID),
            (try chatState("ready", 7), SlackSetupPlan.channelsID),
        ]
        for (state, expected) in cases {
            #expect(try plan(state).currentID == expected, "\(String(describing: state?.step))")
        }
    }

    @Test func fiveRowsOneDoneByPalAndTheIntroIsNotARow() throws {
        let first = try engine(try plan(try chatState("not_started", 0)))
        #expect(first.stepCount == 5)
        #expect(first.positionLabel == "Step 1 of 5")
        #expect(first.checklist.map(\.title) == ["Get a Slack code", "Create the Slack app", "Click Allow", "Who are you?", "Pick channels"])
        #expect(first.checklist.map(\.isAutomatic) == [false, true, false, false, false])
        #expect(first.primaryAction == .work)
        #expect(first.isPrimaryEnabled)
    }

    @Test func guidedTasksJoinTheChecklistInTheOrderTheGatewayAsksForThem() throws {
        let pending = try chatState(
            "needs_manual_step", 4, action: ["kind": "button", "action_id": "app_level_credential", "link": "https://api.slack.com/apps/A1/general"],
            done: ["set_icon"]
        )
        let guided = try plan(pending, guided: ["set_icon", "app_level_credential"])
        #expect(guided.currentID == "manual-app_level_credential")
        let flow = try engine(guided)
        #expect(flow.stepCount == 7)
        #expect(flow.positionLabel == "Step 4 of 7")
        #expect(flow.current.pageLink?.url.absoluteString == "https://api.slack.com/apps/A1/general")
        #expect(flow.current.fields.map(\.id) == [SlackSetupPlan.appKeyField])
    }

    @Test func anAutomaticWorkspaceHasNoGuidedRows() throws {
        let flow = try engine(try plan(try chatState("needs_manual_step", 4), guided: []))
        #expect(flow.stepCount == 5)
        #expect(flow.current.id == SlackSetupPlan.allowID)
    }

    @Test func theBotTokenFallbackIsAQuietSkipFromAllowAndNotARow() throws {
        let fallback: [String: Any] = ["kind": "enter_text", "action_id": "bot_token"]
        let offered = try plan(try chatState("needs_allow", 4, fallback: fallback))
        var flow = try engine(offered)
        #expect(flow.current.skipTitle == "Paste a bot token instead")
        #expect(flow.stepCount == 5)
        let skipped = flow.skip()
        #expect(skipped)
        #expect(flow.current.id == SlackSetupPlan.botTokenID)
        #expect(flow.positionLabel == "Step 3 of 5")
        #expect(flow.current.fields.first?.prefixes == ["xoxb-"])
        #expect(flow.canGoBack)
        let returned = flow.back()
        #expect(returned)
        #expect(flow.current.id == SlackSetupPlan.allowID)

        let notOffered = try plan(try chatState("needs_allow", 4))
        #expect(!notOffered.steps.contains { $0.id == SlackSetupPlan.botTokenID })
        #expect(try engine(notOffered).current.skipTitle == nil)
    }

    @Test func stepsThatTheGatewayAlreadyPassedCannotBeGoneBackTo() throws {
        for state in ["needs_credential", "needs_owner", "ready"] {
            let flow = try engine(try plan(try chatState(state, 3)))
            #expect(!flow.canGoBack, "\(state)")
        }
    }

    @Test func theTwoSlackTokensAreCheckedLiveAndNotSwappable() throws {
        var flow = try engine(try plan(try chatState("needs_credential", 2)))
        #expect(!flow.isPrimaryEnabled)
        flow.setValue("xoxe-1-" + String(repeating: "a", count: 20), for: SlackSetupPlan.accessField)
        #expect(flow.shape(of: SlackSetupPlan.accessField) == .wrongStart(["xoxe.xoxp-"]))
        flow.setValue("xoxe.xoxp-1-" + String(repeating: "a", count: 20), for: SlackSetupPlan.accessField)
        flow.setValue("xoxe.xoxp-1-" + String(repeating: "b", count: 20), for: SlackSetupPlan.refreshField)
        #expect(flow.shape(of: SlackSetupPlan.refreshField) == .wrongStart(["xoxe-"]))
        #expect(!flow.isPrimaryEnabled)
        flow.setValue("xoxe-1-" + String(repeating: "b", count: 20), for: SlackSetupPlan.refreshField)
        #expect(flow.isPrimaryEnabled)
    }

    @Test func theMemberIDMustLookLikeASlackMemberID() throws {
        var flow = try engine(try plan(try chatState("needs_owner", 6)))
        flow.setValue("alice", for: SlackSetupPlan.memberField)
        #expect(flow.shape(of: SlackSetupPlan.memberField) == .wrongStart(["U", "W"]))
        #expect(!flow.isPrimaryEnabled)
        flow.setValue("U04ABC123", for: SlackSetupPlan.memberField)
        #expect(flow.isPrimaryEnabled)
    }

    @Test func pickingChannelsFinishesTheFlow() throws {
        var flow = try engine(try plan(try chatState("ready", 7)))
        #expect(flow.current.primaryTitle == "Finish")
        let finished = flow.advance()
        #expect(finished)
        #expect(flow.isFinished)
        #expect(flow.checklist.allSatisfy { $0.state == .done })
    }

    @Test(arguments: [
        ("credential_rejected", "reenter_credential", SlackSetupPlan.credentialID),
        ("credential_expired", "reenter_credential", SlackSetupPlan.credentialID),
        ("app_create_failed", "retry", SlackSetupPlan.creatingID),
        ("allow_denied", "restart_allow", SlackSetupPlan.allowID),
        ("install_failed", "retry", SlackSetupPlan.allowID),
        ("provider_unreachable", "retry", SlackSetupPlan.credentialID),
    ])
    func everySetupErrorIsOnePlainSentenceWithItsCodeBehindDetails(code: String, fix: String, target: String) throws {
        let failed = try plan(try chatState("error", 8, error: ["code": code, "fix": fix]))
        let status = try #require(failed.failure)
        #expect(status.code == code)
        #expect(!status.title.isEmpty && !status.reason.isEmpty && !status.actionTitle.isEmpty)
        #expect(!status.reason.contains(code), "the code stays behind Details")
        #expect(failed.currentID == target)
    }

    @Test func aRejectedTokenReadsLikeTheApprovedMockup() throws {
        let status = SlackSetupPlan.status(for: .credentialRejected, displayName: "Pal")
        #expect(status.title == "Slack did not accept that token")
        #expect(status.reason == "Copy the token again from Slack and paste it here.")
        #expect(status.actionTitle == "Edit token")
        #expect(status.kind == .vendorRefusedValue)
    }

    @Test func aDeniedAllowAsksForOneAction() {
        let status = SlackSetupPlan.status(for: .allowDenied, displayName: "Pal")
        #expect(status.title == "Slack did not get your Allow")
        #expect(status.actionTitle == "Open Slack again")
    }

    @Test func nothingIsAFailureWhileTheGatewayIsHealthy() throws {
        #expect(try plan(try chatState("needs_credential", 2)).failure == nil)
        #expect(try plan(nil).failure == nil)
    }

    @Test func followingTheGatewayKeepsTypedValuesAndMovesTheStep() throws {
        var flow = try engine(try plan(try chatState("needs_credential", 2)))
        flow.setValue("xoxe.xoxp-1-abc", for: SlackSetupPlan.accessField)
        let next = try plan(try chatState("creating_app", 3))
        let moved = try #require(flow.following(steps: next.steps, at: next.currentID, failure: nil))
        #expect(moved.current.id == SlackSetupPlan.creatingID)
        #expect(moved.phase == .ready)

        let back = try plan(try chatState("needs_credential", 4))
        let again = try #require(flow.following(steps: back.steps, at: back.currentID, failure: nil))
        #expect(again.value(for: SlackSetupPlan.accessField) == "xoxe.xoxp-1-abc")
    }

    @Test func followingShowsAGatewayFailureAndKeepsAWorkingStepWorking() throws {
        var flow = try engine(try plan(try chatState("creating_app", 3)))
        let started = flow.startWork()
        #expect(started)
        let same = try plan(try chatState("creating_app", 4))
        let working = try #require(flow.following(steps: same.steps, at: same.currentID, failure: nil))
        #expect(working.phase == .working)

        let broken = try plan(try chatState("error", 5, error: ["code": "app_create_failed", "fix": "retry"]))
        let failed = try #require(working.following(steps: broken.steps, at: broken.currentID, failure: broken.failure))
        #expect(failed.failure?.code == "app_create_failed")
    }

    @Test func aStepThatWasWorkingStopsWorkingWhenTheGatewayMovesOn() throws {
        var flow = try engine(try plan(try chatState("creating_app", 3)))
        let started = flow.startWork()
        #expect(started)
        let moved = try plan(try chatState("needs_manual_step", 4))
        let next = try #require(flow.following(steps: moved.steps, at: moved.currentID, failure: nil))
        #expect(next.phase == .ready)
        #expect(next.current.id != SlackSetupPlan.creatingID)
    }

    @Test func aGatewayDrivenStepStaysWhereTheGatewayIsAfterItsWorkEnds() throws {
        var flow = try engine(try plan(try chatState("needs_credential", 2)))
        flow.setValue("xoxe.xoxp-1-" + String(repeating: "a", count: 20), for: SlackSetupPlan.accessField)
        flow.setValue("xoxe-1-" + String(repeating: "b", count: 20), for: SlackSetupPlan.refreshField)
        let started = flow.startWork()
        #expect(started)
        flow.finishWork(advance: false)
        #expect(flow.current.id == SlackSetupPlan.credentialID)
        #expect(flow.phase == .ready)
    }
}
