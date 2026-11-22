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

    @Test func aRejectedAppKeyReturnsToItsOwnStepAndNamesTheBotsApp() throws {
        let rejected = try chatState(
            "error", 9, done: ["set_icon"], error: ["code": "credential_rejected", "fix": "reenter_credential"], resume: "needs_manual_step"
        )
        let plan = try plan(rejected, guided: ["set_icon", "app_level_credential"])
        #expect(plan.currentID == SlackSetupPlan.manualID(.appLevelCredential))
        let reason = try #require(plan.failure?.reason)
        #expect(reason.contains("Pal's own Slack app") && reason.contains("Basic Information") && reason.contains("App-Level Tokens"))
        let config = try chatState("error", 9, error: ["code": "credential_rejected", "fix": "reenter_credential"], resume: "needs_credential")
        let other = try self.plan(config, guided: ["set_icon", "app_level_credential"])
        #expect(other.currentID == SlackSetupPlan.credentialID)
        #expect(other.failure?.reason.contains("App-Level Tokens") == false)
    }

    private static let everyGuidedTask = ["set_icon", "app_level_credential", "gateway_redirect"]

    private func guidedEngine(_ step: String) throws -> StepFlowEngine {
        let done = Array(Self.everyGuidedTask.prefix { $0 != step })
        let state = step == "allow"
            ? try chatState("needs_allow", 9, action: ["kind": "open_link", "action_id": "allow", "link": "https://slack.com/oauth"], done: done)
            : try chatState("needs_manual_step", 9, action: ["kind": "button", "action_id": step], done: done)
        return try engine(try plan(state, guided: Self.everyGuidedTask))
    }

    @Test func backIsOfferedOnGuidedStepsAfterTheFirstAndOnAllowOnly() throws {
        let guided = try plan(nil, guided: Self.everyGuidedTask)
        let offered: [(String, Bool)] = [
            (SlackSetupPlan.introID, false), (SlackSetupPlan.credentialID, false), (SlackSetupPlan.creatingID, false),
            (SlackSetupPlan.manualID(.setIcon), false), (SlackSetupPlan.manualID(.appLevelCredential), true),
            (SlackSetupPlan.manualID(.gatewayRedirect), true), (SlackSetupPlan.allowID, true),
            (SlackSetupPlan.ownerID, false), (SlackSetupPlan.channelsID, false),
        ]
        for (id, back) in offered {
            #expect(try #require(guided.steps.first { $0.id == id }).allowsBack == back, "\(id)")
        }
    }

    @Test func allowHasNoBackWhenTheWorkspaceNeedsNoGuidedStep() throws {
        let automatic = try plan(try chatState("needs_allow", 4), guided: [])
        #expect(try #require(automatic.steps.first { $0.id == SlackSetupPlan.allowID }).allowsBack == false)
        #expect(!(try engine(automatic)).canGoBack)
    }

    @Test func backFromAllowReopensTheLastGuidedStepAndBackFromEachGuidedStepReopensTheOneBefore() throws {
        let cases: [(current: String, reopens: ChatProviderCapability?)] = [
            ("allow", .gatewayRedirect), ("gateway_redirect", .appLevelCredential), ("app_level_credential", .setIcon), ("set_icon", nil),
        ]
        for (current, reopens) in cases {
            let flow = try guidedEngine(current)
            #expect(flow.canGoBack == (reopens != nil), "\(current)")
            guard let reopens else { continue }
            #expect(SlackSetupPlan.reopening(back: try #require(flow.previousStep)) == reopens, "\(current)")
        }
    }

    @Test func backFromTheBotTokenStepToAllowSendsNothingToTheGateway() throws {
        let fallback: [String: Any] = ["kind": "enter_text", "action_id": "bot_token"]
        var flow = try engine(try plan(try chatState("needs_allow", 4, fallback: fallback), guided: Self.everyGuidedTask))
        let skipped = flow.skip()
        #expect(skipped && flow.current.id == SlackSetupPlan.botTokenID)
        let target = try #require(flow.previousStep)
        #expect(target.id == SlackSetupPlan.allowID)
        #expect(SlackSetupPlan.reopening(back: target) == nil)
    }

    @Test func aRefusedBackLeavesANoteOnTheCurrentStepAndNowhereElse() throws {
        let state = try chatState("needs_allow", 9, action: ["kind": "open_link", "action_id": "allow", "link": "https://slack.com/oauth"])
        let refused = SlackSetupPlan(displayName: "Pal", provider: try chatProvider(guided: Self.everyGuidedTask), state: state, backUnavailable: true)
        let noted = refused.steps.filter { $0.note != nil }
        #expect(noted.map(\.id) == [SlackSetupPlan.allowID])
        #expect(noted.first?.note == "Can't go back right now. Updating Pal on your computer may help.")
        #expect(try plan(state, guided: Self.everyGuidedTask).steps.allSatisfy { $0.note == nil })
    }
}
