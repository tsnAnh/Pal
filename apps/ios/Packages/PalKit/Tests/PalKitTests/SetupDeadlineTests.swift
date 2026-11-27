import Foundation
import PalBotProfile
import PalConnect
import PalProtocol
import PalTransport
import Synchronization
import Testing

func neverAnswers() async -> Never {
    await withUnsafeContinuation { (_: UnsafeContinuation<Never, Never>) in }
}

let quickLimits = SetupLimits(call: .milliseconds(40), step: .milliseconds(120))
private let pastTheStepLimit = Duration.milliseconds(400)

private struct SilencedChatInstallClient: ChatInstallClient {
    let base: FakeChatInstallClient
    let silent: Set<String>

    private func hush(_ name: String) async {
        if silent.contains(name) { await neverAnswers() }
    }

    func providers() async throws -> [ChatCapabilitiesWire] { await hush("providers"); return try await base.providers() }
    func status(_ scope: ChatInstallScope) async throws -> ChatInstallStatusResult { await hush("status"); return try await base.status(scope) }
    func channelAccess(_ scope: ChatInstallScope) async throws -> [ChatChannelAccessWire] {
        await hush("channelAccess")
        return try await base.channelAccess(scope)
    }
    func begin(_ scope: ChatInstallScope) async throws { await hush("begin"); try await base.begin(scope) }
    func advance(_ scope: ChatInstallScope, _ advance: ChatInstallAdvance) async throws {
        await hush("advance")
        try await base.advance(scope, advance)
    }
    func spaces(_ scope: ChatInstallScope) async throws -> [ChatSpaceRefWire] { await hush("spaces"); return try await base.spaces(scope) }
    func join(_ scope: ChatInstallScope, spaceId: String) async throws -> ChatSpaceJoinResult {
        await hush("join")
        return try await base.join(scope, spaceId: spaceId)
    }
    func bindings(_ scope: ChatInstallScope) async throws -> [ChatBindingWire] { await hush("bindings"); return try await base.bindings(scope) }
    func revoke(_ scope: ChatInstallScope) async throws { await hush("revoke"); try await base.revoke(scope) }
    func updateIdentity(_ scope: ChatInstallScope) async throws -> ChatIdentityUpdateResult {
        await hush("updateIdentity")
        return try await base.updateIdentity(scope)
    }
    func setIcon(_ scope: ChatInstallScope, png: Data) async throws { await hush("setIcon") }
    func reconnect(_ scope: ChatInstallScope) async throws -> ChatInstallStatusResult {
        await hush("reconnect")
        return try await base.reconnect(scope)
    }
    func storeSecret(label: String, value: String) async throws -> String {
        await hush("storeSecret")
        return try await base.storeSecret(label: label, value: value)
    }
}

private final class Attempts: Sendable {
    private let counted = Mutex(0)

    var count: Int { counted.withLock { $0 } }

    func next() -> Int { counted.withLock { $0 += 1; return $0 } }
}

private func step(_ id: String, _ kind: FlowStep.Kind) -> FlowStep {
    FlowStep(id: id, title: id, kind: kind)
}

private let waitingSteps = [
    step("intro", .instruction(openPage: nil)),
    step("installing", .waiting(title: "Finishing", body: "")),
    step("channels", .instruction(openPage: nil)),
    step("done", .success(title: "Done", body: "")),
]

@MainActor
private func flow(_ steps: [FlowStep], limits: SetupLimits? = quickLimits, runner: @escaping StepFlowModel.Runner = { _, _ in },
                  prepare: StepFlowModel.Preparer? = nil) throws -> StepFlowModel {
    StepFlowModel(engine: try #require(StepFlowEngine(flowID: "limits", steps: steps)), runner: runner, prepare: prepare, limits: limits)
}

@Suite("Setup deadlines")
@MainActor
struct SetupDeadlineTests {
    @Test func theProductionLimitsAreThirtySecondsForACallAndTwoMinutesForAStep() {
        #expect(SetupLimits() == SetupLimits(call: .seconds(30), step: .seconds(120)))
    }

    @Test func workThatIgnoresCancellationStillEndsAtTheLimit() async {
        await #expect(throws: DeadlineExceeded.self) {
            try await Deadline.run(.milliseconds(40)) { await neverAnswers() }
        }
    }

    @Test func anAnswerInTimeAndItsErrorPassThrough() async throws {
        struct Refused: Error {}
        #expect(try await Deadline.run(.seconds(5)) { 7 } == 7)
        await #expect(throws: Refused.self) { try await Deadline.run(.seconds(5)) { () -> Int in throw Refused() } }
    }

    @Test func cancellingTheCallerEndsTheWait() async {
        let waiting = Task { try await Deadline.run(.seconds(30)) { await neverAnswers() } }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }

    @Test(arguments: ["providers", "status"])
    func aSilentGatewayEndsTheLoadInAPlainErrorWithRetry(method: String) async throws {
        let base = try FakeChatInstallClient([try chatProvider()], try chatState("not_started", 0))
        let install = ChatInstallModel(
            botName: "pal", preferredProvider: "slack", client: SilencedChatInstallClient(base: base, silent: [method]), limits: quickLimits
        )
        await install.load()
        #expect(install.screen == .unavailable)
        #expect(install.loadError == .timedOut)
        #expect(install.primaryAction == .reload)
    }

    @Test func aSilentActionStopsWorkingAndSaysSo() async throws {
        let base = try FakeChatInstallClient([try chatProvider()], try chatState("not_started", 0))
        let install = ChatInstallModel(
            botName: "pal", preferredProvider: "slack", client: SilencedChatInstallClient(base: base, silent: ["begin"]), limits: quickLimits
        )
        await install.load()
        await install.begin()
        #expect(!install.isWorking)
        #expect(install.noticeError == .timedOut)
    }

    @Test func aSilentSlackStatusEndsInsteadOfSpinning() async {
        let service = SlackService(gateway: BotsGateway { _, _ in await neverAnswers() }, callLimit: .milliseconds(40))
        await #expect(throws: BotsError.unavailable) { _ = try await service.status(profile: "pal") }
    }

    @Test func aStepWhoseWorkNeverAnswersFailsInPlainWordsAndRetryRunsItAgain() async throws {
        let attempts = Attempts()
        let model = try flow([step("creating", .automatic), step("done", .success(title: "Done", body: ""))], runner: { _, _ in
            if attempts.next() == 1 { await neverAnswers() }
        })
        await model.start()
        let failure = try #require(model.engine.failure)
        #expect(failure == .tookTooLong)
        #expect(!failure.reason.contains("creating") && !failure.title.contains("creating"))
        await model.recover(from: failure)
        #expect(attempts.count == 2)
        #expect(model.engine.current.id == "done")
    }

    @Test func aStepThatNeverFinishesPreparingFails() async throws {
        var waits = step("invite", .instruction(openPage: nil))
        waits.prepares = true
        let model = try flow([waits, step("done", .success(title: "Done", body: ""))], prepare: { _ in await neverAnswers() })
        await model.start()
        #expect(model.engine.failure == .tookTooLong)
    }

    @Test func aWaitingStepThatHearsNothingFailsAndRetryWaitsAgain() async throws {
        let model = try flow(waitingSteps)
        model.follow(steps: waitingSteps, at: "installing", failure: nil)
        try await Task.sleep(for: pastTheStepLimit)
        #expect(model.engine.current.id == "installing")
        #expect(model.engine.failure == .tookTooLong)
        await model.retryAfterFailure()
        #expect(model.engine.failure == nil)
        try await Task.sleep(for: pastTheStepLimit)
        #expect(model.engine.failure == .tookTooLong)
    }

    @Test func anAnswerBeforeTheLimitEndsTheWait() async throws {
        let model = try flow(waitingSteps)
        model.follow(steps: waitingSteps, at: "installing", failure: nil)
        model.follow(steps: waitingSteps, at: "channels", failure: nil)
        try await Task.sleep(for: pastTheStepLimit)
        #expect(model.engine.current.id == "channels")
        #expect(model.engine.failure == nil)
    }

    @Test func goingBackAndReturningToAWaitStartsANewLimit() async throws {
        let model = try flow(waitingSteps)
        model.follow(steps: waitingSteps, at: "installing", failure: nil)
        await model.back()
        #expect(model.engine.current.id == "intro")
        try await Task.sleep(for: pastTheStepLimit)
        #expect(model.engine.failure == nil)
        model.follow(steps: waitingSteps, at: "installing", failure: nil)
        try await Task.sleep(for: pastTheStepLimit)
        #expect(model.engine.failure == .tookTooLong)
    }

    @Test func flowsWithoutLimitsKeepWaiting() async throws {
        let model = try flow(waitingSteps, limits: nil)
        model.follow(steps: waitingSteps, at: "installing", failure: nil)
        try await Task.sleep(for: pastTheStepLimit)
        #expect(model.engine.failure == nil)
    }
}
