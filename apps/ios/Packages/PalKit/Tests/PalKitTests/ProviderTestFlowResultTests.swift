import Foundation
import Testing

@testable import PalBotProfile
@testable import PalProtocol

@MainActor
@Suite("Provider test flow, results")
struct ProviderTestFlowResultTests {
    private let backend = FakeProviderBackend()
    private let sleeper = ManualSleeper()

    private func makeFlow() -> ProviderTestFlow { makeTestFlow(backend, sleeper) }

    @Test("a result that arrives at once never shows the slow notice")
    func fastResult() async {
        let flow = makeFlow()
        flowWritten(flow)
        await flow.test()
        sleeper.release(.seconds(10))
        sleeper.release(.seconds(35))
        for _ in 0..<200 { await Task.yield() }
        #expect(flow.canSaveAndContinue)
    }

    @Test(
        "each failure kind lands in its state",
        arguments: [
            (ProviderTestFailureKind.timeout, "The provider answered too slowly."), (.quota, "No credit left."),
            (.unsupported, "Not offered here."), (.other, "Something broke."),
        ])
    func failureKinds(kind: ProviderTestFailureKind, reason: String) async {
        let flow = makeFlow()
        flowWritten(flow)
        backend.script(flowFailure(kind, reason))
        await flow.test()
        #expect(flow.state == .failed(reason: reason, kind: kind))
        #expect(!flow.canSignInAgain && !flow.canChangeModelAfterFailure)
    }

    @Test("a network failure is offline, and a sign-in failure offers to sign in again only for a written credential")
    func networkAndAuth() async {
        let flow = makeFlow()
        flowWritten(flow)
        backend.script(flowFailure(.network), flowFailure(.auth, "Sign in again."))
        await flow.test()
        #expect(flow.state == .offline)
        await flow.test()
        #expect(flow.state == .failed(reason: "Sign in again.", kind: .auth) && flow.canSignInAgain)

        let keyed = makeFlow()
        flowStaged(keyed)
        backend.script(flowFailure(.auth, "That key was rejected."))
        await keyed.test()
        #expect(keyed.state == .failed(reason: "That key was rejected.", kind: .auth) && !keyed.canSignInAgain)
    }

    @Test("a failed result with no error still says the test did not pass")
    func failureWithoutError() async {
        let flow = makeFlow()
        flowWritten(flow)
        backend.script(ProviderTestResult(ok: false, provider: "x", model: "y", latencyMilliseconds: 0))
        await flow.test()
        #expect(flow.state == .failed(reason: ProviderTestFlow.didNotPass, kind: .other))
    }
}
