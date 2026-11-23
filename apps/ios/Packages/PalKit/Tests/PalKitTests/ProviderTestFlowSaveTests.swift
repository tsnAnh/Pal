import Foundation
import Testing

@testable import PalBotProfile
@testable import PalProtocol

@MainActor
@Suite("Provider test flow, saving and leaving")
struct ProviderTestFlowSaveTests {
    private let backend = FakeProviderBackend()
    private let sleeper = ManualSleeper()

    private func makeFlow() -> ProviderTestFlow { makeTestFlow(backend, sleeper) }

    @Test("a failed save keeps the key so Retry works, then a save clears it")
    func saveFailureThenRetry() async {
        let flow = makeFlow()
        flowStaged(flow)
        await flow.test()
        backend.replySave("Couldn't save the key. Try again in a moment.", nil)
        #expect(await flow.saveAndContinue() == false)
        #expect(flow.state == .failed(reason: ProviderTestFlow.saveFailed, kind: .other))
        #expect(flow.hasStagedSecret && !flow.canSaveAndContinue && flow.canTest)
        #expect(backend.pins.isEmpty)

        await flow.test()
        #expect(backend.tests.count == 2 && backend.tests.allSatisfy { $0.apiKey == SecretString(flowSecret) })
        #expect(await flow.saveAndContinue())
        #expect(backend.saves.count == 2 && backend.saves.allSatisfy { $0.apiKey == SecretString(flowSecret) })
        #expect(backend.pins.count == 1)
        #expect(!flow.hasStagedSecret)
    }

    @Test("a failed pin is reported the same way and keeps the staged key")
    func pinFailure() async {
        let flow = makeFlow()
        flowStaged(flow)
        await flow.test()
        backend.replyPin("Couldn't change the model. Nothing was changed.")
        #expect(await flow.saveAndContinue() == false)
        #expect(flow.state == .failed(reason: ProviderTestFlow.saveFailed, kind: .other))
        #expect(flow.hasStagedSecret)
        #expect(backend.saves.count == 1 && backend.pins.count == 1)
    }

    @Test("a save drops the staged key and the finished flow cannot test again")
    func saveClearsTheKey() async {
        let flow = makeFlow()
        flowStaged(flow)
        await flow.test()
        #expect(flow.hasStagedSecret)
        #expect(await flow.saveAndContinue())
        #expect(!flow.hasStagedSecret && flow.state == .idle && !flow.canTest && !flow.canSaveAndContinue)
        await flow.test()
        #expect(backend.tests.count == 1)
        #expect(await flow.saveAndContinue() == false)
        #expect(backend.saves.count == 1 && backend.pins.count == 1)
    }

    @Test("no staged value leaves a description of the flow or its request")
    func secretNeverDescribed() async {
        let flow = makeFlow()
        flowStaged(flow)
        await flow.test()
        var dumped = ""
        dump(flow, to: &dumped)
        #expect(!dumped.contains(flowSecret))
        let request = ProviderTestRequest(provider: "openrouter", model: "m", apiKey: SecretString(flowSecret))
        #expect(!"\(request)".contains(flowSecret) && !String(reflecting: request).contains(flowSecret))
    }

    @Test("discarding a staged provider drops the key without calling the backend")
    func discard() async {
        let flow = makeFlow()
        flowStaged(flow)
        flow.discard()
        #expect(!flow.hasStagedSecret && flow.state == .idle && flow.provider == nil)
        await flow.test()
        #expect(backend.tests.isEmpty && backend.removals.isEmpty)
    }

    @Test("skipping before any pass removes a credential this flow wrote, exactly once")
    func skipRemovesWhatItWrote() async {
        let flow = makeFlow()
        flow.beginSigningIn(provider: flowCodex)
        flow.credentialWritten()
        flow.select(model: "gpt-5")
        backend.script(flowFailure(.other))
        await flow.test()
        await flow.skip()
        await flow.skip()
        #expect(backend.removals == ["openai-codex"])
        #expect(flow.state == .idle && flow.provider == nil && !flow.ownsCredential)
    }

    @Test("skipping never removes a connection that was already there")
    func skipKeepsExistingConnection() async {
        let flow = makeFlow()
        flowWritten(flow, owns: false)
        backend.script(flowFailure(.other))
        await flow.test()
        #expect(!flow.canRemove)
        await flow.skip()
        #expect(backend.removals.isEmpty && flow.state == .idle)
    }

    @Test("skipping after a pass keeps the credential, but not once the model changed")
    func skipAfterPassKeeps() async {
        let flow = makeFlow()
        flowWritten(flow)
        await flow.test()
        flow.select(model: "gpt-5-mini")
        await flow.skip()
        #expect(backend.removals == ["openai-codex"])

        let direct = makeFlow()
        flowWritten(direct)
        await direct.test()
        await direct.skip()
        #expect(backend.removals == ["openai-codex"] && direct.state == .idle)
    }

    @Test("skipping a staged provider never calls remove and drops the key")
    func skipStaged() async {
        let flow = makeFlow()
        flowStaged(flow)
        await flow.skip()
        #expect(backend.removals.isEmpty && !flow.hasStagedSecret && flow.state == .idle)
    }

    @Test("skipping during a test stops it and removes an unproven credential")
    func skipWhileTesting() async {
        let flow = makeFlow()
        flowWritten(flow)
        let gate = ResultGate()
        backend.script(.gate(gate))
        let task = Task { await flow.test() }
        _ = await flowSettled { flow.state == .testing && backend.tests.count == 1 }
        await flow.skip()
        await task.value
        gate.open(flowPass())
        for _ in 0..<200 { await Task.yield() }
        #expect(flow.state == .idle && backend.removals == ["openai-codex"])
    }

    @Test("remove after a failure calls the backend once and returns to the start")
    func explicitRemove() async {
        let flow = makeFlow()
        flowWritten(flow)
        #expect(flow.canRemove)
        backend.script(flowFailure(.auth))
        await flow.test()
        #expect(flow.canRemove)
        #expect(await flow.remove())
        #expect(backend.removals == ["openai-codex"] && flow.state == .idle && !flow.canRemove)
        #expect(await flow.remove() == false)
        #expect(backend.removals.count == 1)
    }

    @Test("remove is offered only for a credential this flow wrote, and a refused removal changes nothing")
    func removeGuards() async {
        let existing = makeFlow()
        flowWritten(existing, owns: false)
        #expect(!existing.canRemove)
        #expect(await existing.remove() == false)
        #expect(backend.removals.isEmpty)

        let keyed = makeFlow()
        flowStaged(keyed)
        #expect(!keyed.canRemove)

        let refused = makeFlow()
        flowWritten(refused)
        backend.replyRemove(false)
        backend.script(flowFailure(.network))
        await refused.test()
        #expect(refused.canRemove)
        #expect(await refused.remove() == false)
        #expect(refused.state == .offline && refused.provider != nil)

        let passed = makeFlow()
        flowWritten(passed)
        await passed.test()
        #expect(!passed.canRemove)
    }

    @Test("signing in again after a rejected sign-in returns to a fresh test, or back to the failure when cancelled")
    func signInAgain() async {
        let flow = makeFlow()
        flowWritten(flow)
        backend.script(flowFailure(.auth, "Sign in again."))
        await flow.test()
        #expect(flow.canSignInAgain)
        flow.beginSigningIn(provider: flowCodex)
        #expect(flow.state == .signingIn && !flow.canSignInAgain && !flow.canTest)
        flow.signInCancelled()
        #expect(flow.state == .failed(reason: "Sign in again.", kind: .auth))

        flow.beginSigningIn(provider: flowCodex)
        flow.credentialWritten()
        #expect(flow.state == .awaitingTest && flow.ownsCredential && flow.model == "gpt-5")
        await flow.test()
        #expect(flow.canSaveAndContinue)
    }

    @Test("a first sign-in that is cancelled leaves nothing to remove")
    func firstSignInCancelled() async {
        let flow = makeFlow()
        flow.beginSigningIn(provider: flowCodex)
        flow.signInCancelled()
        #expect(flow.state == .idle && !flow.ownsCredential)
        await flow.skip()
        #expect(backend.removals.isEmpty)
    }
}
