import Foundation
import Testing

@testable import PalBotProfile
@testable import PalProtocol

@MainActor
@Suite("Provider test flow, proof and rollback")
struct ProviderTestFlowGuardTests {
    private let backend = FakeProviderBackend()
    private let sleeper = ManualSleeper()

    private func makeFlow() -> ProviderTestFlow { makeTestFlow(backend, sleeper) }

    @Test("a failed retest takes the earlier pass back, so skipping removes the token this flow wrote")
    func failedRetestForgetsThePass() async {
        let flow = makeFlow()
        flowWritten(flow)
        backend.script(flowPass(), flowFailure(.auth, "Sign in again."))
        await flow.test()
        #expect(!flow.holdsUnprovenWrittenCredential)
        await flow.test()
        #expect(flow.holdsUnprovenWrittenCredential)
        #expect(await flow.skip())
        #expect(backend.removals == ["openai-codex"])
    }

    @Test("giving up on a retest also takes the pass back")
    func timedOutRetestForgetsThePass() async {
        let flow = makeFlow()
        flowWritten(flow)
        await flow.test()
        let gate = ResultGate()
        backend.script(.gate(gate))
        let task = Task { await flow.test() }
        _ = await flowSettled { flow.state == .testing && backend.tests.count == 2 }
        sleeper.release(ProviderTestFlow.defaultGiveUpAfter)
        await task.value
        #expect(flow.holdsUnprovenWrittenCredential)
        gate.open(flowPass())
    }

    @Test("a model change takes the pass back, even through an offline retest")
    func modelChangeForgetsThePass() async {
        let flow = makeFlow()
        flowWritten(flow)
        await flow.test()
        #expect(!flow.holdsUnprovenWrittenCredential)
        flow.select(model: "gpt-5-mini")
        #expect(flow.holdsUnprovenWrittenCredential)

        let offline = makeFlow()
        flowWritten(offline)
        backend.script(flowPass(), flowFailure(.network))
        await offline.test()
        await offline.test()
        #expect(offline.state == .offline && !offline.holdsUnprovenWrittenCredential)
        offline.select(model: "gpt-5-mini")
        #expect(offline.holdsUnprovenWrittenCredential)
    }

    @Test("skip says whether the removal it attempted worked, and true when none was needed")
    func skipReportsTheRemoval() async {
        let flow = makeFlow()
        flowWritten(flow)
        backend.script(flowFailure(.other))
        await flow.test()
        backend.replyRemove(false)
        #expect(await flow.skip() == false)

        let existing = makeFlow()
        flowWritten(existing, owns: false)
        #expect(await existing.skip())

        let passed = makeFlow()
        flowWritten(passed)
        await passed.test()
        backend.replyRemove(false)
        #expect(await passed.skip())
    }

    @Test("clearing the model drops a pass and blocks testing and saving until a model is chosen")
    func clearModel() async {
        let flow = makeFlow()
        flowStaged(flow)
        await flow.test()
        #expect(flow.canSaveAndContinue)
        flow.clearModel()
        #expect(flow.model == nil && flow.state == .modelChanged)
        #expect(!flow.canTest && !flow.canSaveAndContinue)
        await flow.test()
        #expect(await flow.saveAndContinue() == false)
        #expect(backend.tests.count == 1 && backend.saves.isEmpty && backend.pins.isEmpty)
        flow.select(model: "gpt-5")
        #expect(flow.canTest && flow.state == .modelChanged)
    }

    @Test("clearing the model keeps a failure on screen and ignores a test in flight")
    func clearModelKeepsOtherStates() async {
        let flow = makeFlow()
        flowStaged(flow)
        backend.script(flowFailure(.model, "No such model."))
        await flow.test()
        flow.clearModel()
        #expect(flow.model == nil && flow.state == .failed(reason: "No such model.", kind: .model) && !flow.canTest)

        let running = makeFlow()
        flowWritten(running)
        let gate = ResultGate()
        backend.script(.gate(gate))
        let task = Task { await running.test() }
        _ = await flowSettled { running.state == .testing }
        running.clearModel()
        #expect(running.model == "gpt-5" && running.state == .testing)
        gate.open(flowPass())
        await task.value
    }

    @Test("a save that fails on the pin rolls back what it wrote when the provider was not connected before")
    func pinFailureRollsBack() async {
        let flow = makeFlow()
        flowStaged(flow)
        await flow.test()
        backend.replyPin("Couldn't change the model.")
        #expect(await flow.saveAndContinue() == false)
        #expect(backend.saves.count == 1 && backend.removals == ["openrouter"])
        #expect(flow.state == .failed(reason: ProviderTestFlow.saveFailed, kind: .other) && flow.hasStagedSecret)

        await flow.test()
        #expect(await flow.saveAndContinue())
        #expect(backend.saves.count == 2 && backend.pins.count == 2 && backend.removals.count == 1)
    }

    @Test("a save that fails partway rolls back too")
    func saveFailureRollsBack() async {
        let flow = makeFlow()
        flowStaged(flow, address: "http://localhost:1234/v1")
        await flow.test()
        backend.replySave("Couldn't save the key.")
        #expect(await flow.saveAndContinue() == false)
        #expect(backend.removals == ["openrouter"] && backend.pins.isEmpty)
        #expect(flow.state == .failed(reason: ProviderTestFlow.saveFailed, kind: .other) && flow.hasStagedSecret)
    }

    @Test("a provider that was already connected is never removed by a failed save")
    func connectedBeforeIsKept() async {
        let flow = makeFlow()
        flow.start(
            provider: flowProvider(state: .set), credential: .staged(apiKey: SecretString(flowSecret), baseURL: nil), ownsCredential: false)
        flow.select(model: "gpt-5")
        await flow.test()
        backend.replyPin("Couldn't change the model.")
        #expect(await flow.saveAndContinue() == false)
        backend.replySave("Couldn't save the key.")
        await flow.test()
        #expect(await flow.saveAndContinue() == false)
        #expect(backend.removals.isEmpty)
    }

    @Test("a written credential has nothing staged to roll back when the pin fails")
    func writtenPinFailureRemovesNothing() async {
        let flow = makeFlow()
        flowWritten(flow)
        await flow.test()
        backend.replyPin("Couldn't change the model.")
        #expect(await flow.saveAndContinue() == false)
        #expect(backend.removals.isEmpty && flow.state == .failed(reason: ProviderTestFlow.saveFailed, kind: .other))
    }

    @Test("a rollback that does not work says the save is only partly undone")
    func rollbackFailure() async {
        let flow = makeFlow()
        flowStaged(flow)
        await flow.test()
        backend.replyPin("Couldn't change the model.")
        backend.replyRemove(false)
        #expect(await flow.saveAndContinue() == false)
        #expect(flow.state == .failed(reason: ProviderTestFlow.saveFailedPartway, kind: .other))
    }

    @Test("a save that passes the gate keeps nothing to roll back")
    func successDoesNotRemove() async {
        let flow = makeFlow()
        flowStaged(flow)
        await flow.test()
        #expect(await flow.saveAndContinue())
        #expect(backend.removals.isEmpty)
    }

    @Test("the slow and give-up delays come from the request timeout, and give-up stays above it")
    func delays() {
        #expect(ProviderTestFlow.defaultSlowAfter == .seconds(ProviderTestFlow.defaultSlowAfterSeconds))
        #expect(ProviderTestFlow.defaultGiveUpAfter > .seconds(ProviderTestRequest.defaultTimeoutSeconds))
        #expect(ProviderTestFlow.defaultSlowAfter < .seconds(ProviderTestRequest.defaultTimeoutSeconds))
    }
}
