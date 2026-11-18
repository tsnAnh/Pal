import Foundation
import PalConnect
import Testing

@MainActor
@Suite("Step flow driven by the gateway")
struct StepFlowFollowTests {
    typealias Calls = StepFlowModelTests.Calls

    private let steps: [FlowStep] = [
        FlowStep(id: "go", title: "Go", kind: .action(waitingTitle: "Working", waitingBody: ""), primaryTitle: "Start", showsInChecklist: false),
        FlowStep(id: "paste", title: "Paste", kind: .paste(fields: [SetupField(id: "v", label: "Value", prefixes: ["x"])])),
        FlowStep(id: "done", title: "Done", kind: .success(title: "Done", body: "")),
    ]

    private func model(calls: Calls = Calls(), failing: Bool = false) throws -> StepFlowModel {
        let engine = try #require(StepFlowEngine(flowID: "t", steps: steps))
        return StepFlowModel(
            engine: engine, advancesAfterWork: false,
            runner: { step, _ in
                calls.record(step.id)
                if failing, calls.recorded.count == 1 { throw StepFlowModelTests.Boom() }
            },
            classify: { _ in SetupStatus(code: "offline") }
        )
    }

    @Test func workDoesNotMoveTheStepBecauseTheGatewayDecidesWhereToGo() async throws {
        let calls = Calls()
        let flow = try model(calls: calls)
        await flow.performPrimary()
        #expect(calls.recorded == ["go"])
        #expect(flow.engine.current.id == "go")
        flow.follow(steps: steps, at: "paste", failure: nil)
        #expect(flow.engine.current.id == "paste")
    }

    @Test func aFailureTheGatewayReportsShowsOnTheStep() throws {
        let flow = try model()
        flow.follow(steps: steps, at: "go", failure: SetupStatus(code: "credential_rejected", subject: "Slack"))
        #expect(flow.engine.failure?.kind == .vendorRefusedValue)
    }

    @Test func theDefaultRecoveryRetriesTheStepAfterALocalFailure() async throws {
        let calls = Calls()
        let flow = try model(calls: calls, failing: true)
        await flow.performPrimary()
        #expect(flow.engine.failure?.kind == .offline)
        let failure = try #require(flow.engine.failure)
        await flow.recover(from: failure)
        #expect(calls.recorded == ["go", "go"])
        #expect(flow.engine.failure == nil)
    }

    @Test func aRefusedValueIsEditedNotRetried() async throws {
        let calls = Calls()
        let flow = try model(calls: calls)
        let refused = SetupStatus(code: "invalid_token", subject: "Slack")
        flow.follow(steps: steps, at: "paste", failure: refused)
        await flow.recover(from: refused)
        #expect(calls.recorded.isEmpty)
        #expect(flow.engine.failure == nil)
    }

    @Test func aCustomRecoveryReplacesTheDefault() async throws {
        let calls = Calls()
        let flow = try model(calls: calls)
        let recovered = Calls()
        flow.recovery = { status in recovered.record(status.code) }
        await flow.recover(from: SetupStatus(code: "offline"))
        #expect(recovered.recorded == ["offline"])
        #expect(calls.recorded.isEmpty)
    }
}
