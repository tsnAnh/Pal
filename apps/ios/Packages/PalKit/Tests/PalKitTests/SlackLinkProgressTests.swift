import PalConnect
import Testing

@Suite("Slack link progress")
struct SlackLinkProgressTests {
    private func states(_ progress: SlackLinkProgress) -> [StepFlowEngine.RowState] {
        progress.engine.checklist.map(\.state)
    }

    @Test("connecting marks the earlier steps done and one step current, with no failure")
    func connecting() {
        let progress = SlackLinkProgress(displayName: "Manifest Bot", phase: .connecting, reason: nil)
        #expect(progress.status == nil)
        #expect(progress.failedRowID == nil)
        #expect(progress.engine.failure == nil)
        let rows = progress.engine.checklist
        let expected = [
            SlackSetupPlan.credentialID, SlackSetupPlan.creatingID, SlackSetupPlan.allowID, SlackSetupPlan.ownerID, SlackSetupPlan.channelsID,
        ]
        #expect(rows.map(\.id) == expected)
        #expect(states(progress) == [.done, .done, .current, .upcoming, .upcoming])
    }

    @Test("a failure keeps the current step and carries the real reason with Retry")
    func failed() {
        let reason = "Slack didn't accept a token. Check the bot token and the app token, then update them."
        let progress = SlackLinkProgress(displayName: "Manifest Bot", phase: .failed, reason: reason)
        #expect(progress.status?.title == "Couldn't connect")
        #expect(progress.status?.reason == reason)
        #expect(progress.status?.actionTitle == "Retry")
        #expect(progress.engine.failure == progress.status)
        #expect(progress.failedRowID == SlackSetupPlan.allowID)
        #expect(states(progress) == [.done, .done, .current, .upcoming, .upcoming])
    }

    @Test("a timeout reads Still waiting and keeps the last-state reason")
    func stalled() {
        let reason = "Slack hasn't started for Manifest Bot. Last status: retrying."
        let progress = SlackLinkProgress(displayName: "Manifest Bot", phase: .stalled, reason: reason)
        #expect(progress.status?.title == "Still waiting")
        #expect(progress.status?.reason == reason)
        #expect(progress.status?.actionTitle == "Retry")
        #expect(progress.engine.failure != nil)
    }

    @Test("a failure with no reason still says something plain")
    func fallback() {
        for reason in [nil, ""] {
            let progress = SlackLinkProgress(displayName: "Pal", phase: .failed, reason: reason)
            #expect(progress.status?.reason == SlackLinkProgress.fallbackReason)
        }
    }

    @Test("connected finishes every step and carries no failure")
    func connected() {
        let progress = SlackLinkProgress(displayName: "Manifest Bot", phase: .connected, reason: nil)
        #expect(progress.status == nil)
        #expect(progress.engine.isFinished)
        #expect(states(progress) == [.done, .done, .done, .done, .done])
    }
}
