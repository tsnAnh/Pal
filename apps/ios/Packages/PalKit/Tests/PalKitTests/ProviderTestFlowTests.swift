import Foundation
import Testing

@testable import PalBotProfile
@testable import PalProtocol

@MainActor
@Suite("Provider test flow")
struct ProviderTestFlowTests {
    private let backend = FakeProviderBackend()
    private let sleeper = ManualSleeper()

    private func makeFlow() -> ProviderTestFlow { makeTestFlow(backend, sleeper) }

    private func held(_ flow: ProviderTestFlow) async -> (task: Task<Void, Never>, gate: ResultGate) {
        let gate = ResultGate()
        backend.script(.gate(gate))
        let task = Task { await flow.test() }
        _ = await flowSettled { flow.state == .testing && backend.tests.count == 1 }
        return (task, gate)
    }

    @Test("a staged key and address reach the test but nothing is saved before a pass")
    func nothingSavedBeforeAPass() async {
        let flow = makeFlow()
        flowStaged(flow, address: "http://localhost:1234/v1")
        backend.script(flowFailure(.auth), flowPass())
        await flow.test()
        #expect(backend.saves.isEmpty && backend.pins.isEmpty)
        #expect(await flow.saveAndContinue() == false)
        #expect(backend.saves.isEmpty && backend.pins.isEmpty)
        await flow.test()
        #expect(flow.state == .passed(ProviderTestPass(model: "gpt-5", latencyMilliseconds: 412, replyPreview: "Hi.")))
        #expect(backend.saves.isEmpty && backend.pins.isEmpty)
        #expect(await flow.saveAndContinue())
        #expect(backend.saves == [.init(provider: "openrouter", apiKey: SecretString(flowSecret), baseURL: "http://localhost:1234/v1")])
        #expect(backend.pins == [ModelChoice(provider: "openrouter", model: "gpt-5")])
        let sent = backend.tests
        #expect(sent.count == 2)
        #expect(sent.allSatisfy { $0.apiKey == SecretString(flowSecret) && $0.baseURL == "http://localhost:1234/v1" })
    }

    @Test("a written credential sends no key or address and never saves a staged one")
    func writtenSendsNothingStaged() async {
        let flow = makeFlow()
        flowWritten(flow)
        await flow.test()
        #expect(backend.tests.first?.apiKey == nil && backend.tests.first?.baseURL == nil)
        #expect(backend.tests.first?.provider == "openai-codex" && backend.tests.first?.model == "gpt-5")
        #expect(await flow.saveAndContinue())
        #expect(backend.saves.isEmpty)
        #expect(backend.pins == [ModelChoice(provider: "openai-codex", model: "gpt-5")])
    }

    @Test("a plan that lives on the computer needs nothing written or removed")
    func externalCredential() async {
        let flow = makeFlow()
        flow.start(provider: flowProvider("claude", kind: .cliPlan, state: .set), credential: .external, ownsCredential: false)
        flow.select(model: "sonnet")
        backend.script(flowFailure(.auth))
        await flow.test()
        #expect(!flow.canSignInAgain && !flow.canRemove)
        await flow.skip()
        #expect(backend.removals.isEmpty && flow.state == .idle)
    }

    @Test("save and continue is possible only after a pass")
    func saveOnlyFromPassed() async {
        let flow = makeFlow()
        #expect(!flow.canSaveAndContinue)
        flow.beginSigningIn(provider: flowProvider("openai-codex", kind: .deviceCode))
        #expect(flow.state == .signingIn && !flow.canSaveAndContinue)
        flow.credentialWritten()
        flow.select(model: "gpt-5")
        #expect(flow.state == .awaitingTest && !flow.canSaveAndContinue)
        #expect(await flow.saveAndContinue() == false)

        backend.script(flowFailure(.other), flowFailure(.network), flowPass())
        await flow.test()
        #expect(!flow.canSaveAndContinue)
        await flow.test()
        #expect(flow.state == .offline && !flow.canSaveAndContinue)
        await flow.test()
        #expect(flow.canSaveAndContinue)
        flow.select(model: "gpt-5-mini")
        #expect(flow.state == .modelChanged && !flow.canSaveAndContinue)
        #expect(await flow.saveAndContinue() == false)
        #expect(backend.pins.isEmpty)
    }

    @Test("no save while a test is running or has slowed")
    func noSaveWhileTesting() async {
        let flow = makeFlow()
        flowWritten(flow)
        let (task, gate) = await held(flow)
        #expect(!flow.canSaveAndContinue && !flow.canTest)
        #expect(await flow.saveAndContinue() == false)
        sleeper.release(.seconds(10))
        #expect(await flowSettled { flow.state == .slow })
        #expect(!flow.canSaveAndContinue && !flow.canTest)
        gate.open(flowPass())
        await task.value
        #expect(flow.canSaveAndContinue)
    }

    @Test("changing the model drops a pass, and after a failure it asks for a new test")
    func modelChanges() async {
        let flow = makeFlow()
        flowWritten(flow)
        await flow.test()
        flow.select(model: "gpt-5")
        #expect(flow.canSaveAndContinue)
        flow.select(model: "gpt-5-mini")
        #expect(flow.state == .modelChanged && flow.model == "gpt-5-mini" && flow.canTest)
        flow.select(model: "gpt-5-nano")
        #expect(flow.state == .modelChanged)

        backend.script(flowFailure(.model, "That model isn't available."))
        await flow.test()
        #expect(flow.state == .failed(reason: "That model isn't available.", kind: .model))
        #expect(flow.canChangeModelAfterFailure)
        flow.select(model: "gpt-5")
        #expect(flow.state == .awaitingTest && !flow.canChangeModelAfterFailure)
    }

    @Test("the model cannot change while signing in, testing or slow")
    func modelLocked() async {
        let flow = makeFlow()
        flowWritten(flow)
        let (task, gate) = await held(flow)
        flow.select(model: "other")
        #expect(flow.model == "gpt-5" && flow.state == .testing)
        sleeper.release(.seconds(10))
        #expect(await flowSettled { flow.state == .slow })
        flow.select(model: "other")
        #expect(flow.model == "gpt-5" && flow.state == .slow)
        gate.open(flowPass())
        await task.value

        flow.beginSigningIn(provider: flowProvider("openai-codex", kind: .deviceCode))
        flow.select(model: "other")
        #expect(flow.model == "gpt-5" && flow.state == .signingIn)
    }

    @Test("retry works from a failure and from offline, and a second pass is possible")
    func retry() async {
        let flow = makeFlow()
        flowStaged(flow)
        backend.script(flowFailure(.quota, "Out of credit."), flowFailure(.network), flowPass(), flowPass(latency: 90))
        await flow.test()
        #expect(flow.state == .failed(reason: "Out of credit.", kind: .quota) && flow.canTest)
        await flow.test()
        #expect(flow.state == .offline && flow.canTest)
        await flow.test()
        #expect(flow.canSaveAndContinue)
        await flow.test()
        #expect(flow.state == .passed(ProviderTestPass(model: "gpt-5", latencyMilliseconds: 90, replyPreview: "Hi.")))
        #expect(backend.tests.count == 4)
    }

    @Test("testing again while a test runs does nothing")
    func secondTestIsIgnored() async {
        let flow = makeFlow()
        flowWritten(flow)
        let (task, gate) = await held(flow)
        await flow.test()
        #expect(backend.tests.count == 1 && flow.state == .testing)
        gate.open(flowPass())
        await task.value
        #expect(backend.tests.count == 1 && flow.canSaveAndContinue)
    }

    @Test("a slow test says so at ten seconds and its late result still counts")
    func slowThenResult() async {
        let flow = makeFlow()
        flowWritten(flow)
        let (task, gate) = await held(flow)
        sleeper.release(.seconds(10))
        #expect(await flowSettled { flow.state == .slow })
        gate.open(flowPass(latency: 11_000))
        await task.value
        #expect(flow.state == .passed(ProviderTestPass(model: "gpt-5", latencyMilliseconds: 11_000, replyPreview: "Hi.")))
    }

    @Test("giving up shows the timeout and a late result is ignored")
    func giveUp() async {
        let flow = makeFlow()
        flowWritten(flow)
        let (task, gate) = await held(flow)
        sleeper.release(.seconds(35))
        await task.value
        #expect(flow.state == .failed(reason: "The test took too long. Try again.", kind: .timeout))
        gate.open(flowPass())
        for _ in 0..<200 { await Task.yield() }
        #expect(flow.state == .failed(reason: "The test took too long. Try again.", kind: .timeout))
        #expect(!flow.canSaveAndContinue && flow.canTest)
    }

    @Test("cancelling returns to awaiting a test and a late result is ignored")
    func cancel() async {
        let flow = makeFlow()
        flowWritten(flow)
        let (task, gate) = await held(flow)
        flow.cancelTest()
        #expect(flow.state == .awaitingTest)
        await task.value
        gate.open(flowPass())
        for _ in 0..<200 { await Task.yield() }
        #expect(flow.state == .awaitingTest && !flow.canSaveAndContinue)
        flow.cancelTest()
        #expect(flow.state == .awaitingTest)
    }

    @Test("a cancelled test can be started again and only the new result counts")
    func cancelThenRestart() async {
        let flow = makeFlow()
        flowWritten(flow)
        let (first, gate) = await held(flow)
        flow.cancelTest()
        backend.script(flowFailure(.other, "Second try failed."))
        await flow.test()
        gate.open(flowPass())
        await first.value
        for _ in 0..<200 { await Task.yield() }
        #expect(flow.state == .failed(reason: "Second try failed.", kind: .other))
    }
}
