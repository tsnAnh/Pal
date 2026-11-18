import Foundation
import Observation

@MainActor
@Observable
public final class StepFlowModel {
    public typealias Runner = @Sendable (FlowStep, [String: String]) async throws -> Void
    public typealias Classifier = @Sendable (any Error) -> SetupStatus
    public typealias Preparer = @Sendable (FlowStep) async throws -> FlowStep.Kind?

    public private(set) var engine: StepFlowEngine
    public var openPage: @MainActor (URL) -> Void = { _ in }
    public var recovery: (@MainActor (SetupStatus) async -> Void)?

    @ObservationIgnored private let store: any StepFlowProgressStore
    @ObservationIgnored private let runner: Runner
    @ObservationIgnored private let classify: Classifier
    @ObservationIgnored private let prepare: Preparer?
    @ObservationIgnored private let advancesAfterWork: Bool
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var preparedStep: String?

    public init(
        engine: StepFlowEngine, store: any StepFlowProgressStore = InMemoryStepFlowProgressStore(),
        advancesAfterWork: Bool = true, runner: @escaping Runner = { _, _ in },
        classify: @escaping Classifier = { _ in SetupStatus(code: SetupStatusClass.internalFault.rawValue) },
        prepare: Preparer? = nil
    ) {
        self.engine = engine
        self.store = store
        self.advancesAfterWork = advancesAfterWork
        self.runner = runner
        self.classify = classify
        self.prepare = prepare
    }

    public func follow(steps: [FlowStep], at stepID: String, failure: SetupStatus?) {
        if let next = engine.following(steps: steps, at: stepID, failure: failure) { engine = next }
    }

    public func recover(from failure: SetupStatus) async {
        if let recovery {
            await recovery(failure)
            return
        }
        if [.vendorRefusedValue, .serverUnreachable, .notMcpServer].contains(failure.kind) {
            dismissFailure()
        } else {
            await retryAfterFailure()
        }
    }

    public func start() async {
        if engine.index == 0, let progress = await store.load(flowID: engine.flowID),
           let restored = StepFlowEngine(flowID: engine.flowID, steps: engine.steps, resume: progress) {
            engine = restored
        }
        await runAutomaticSteps()
    }

    public func setValue(_ text: String, for fieldID: String) {
        engine.setValue(text, for: fieldID)
    }

    public func setConfirmed(_ id: String, _ on: Bool) {
        engine.setConfirmed(id, on)
    }

    public func setSwitch(_ id: String, _ on: Bool) {
        engine.setSwitch(id, on)
    }

    public func performPrimary() async {
        switch engine.primaryAction {
        case .advance:
            if case .instruction(let link?) = engine.current.kind { openPage(link.url) }
            guard engine.advance() else { return }
            await persist()
        case .work:
            if case .openAndCheck(let open) = engine.current.kind, engine.isPrimaryEnabled { openPage(open.link.url) }
            let before = engine.index
            await runCurrentStep()
            guard engine.index != before else { return }
        case .finish:
            return
        case .none:
            break
        }
        await runAutomaticSteps()
    }

    public func skip() async {
        guard engine.skip() else { return }
        await persist()
        await runAutomaticSteps()
    }

    public func back() async {
        guard engine.back() else { return }
        await persist()
        await prepareCurrentStep()
    }

    public func recheck() async {
        guard case .openAndCheck = engine.current.kind else { return }
        let before = engine.index
        await runCurrentStep()
        guard engine.index != before else { return }
        await runAutomaticSteps()
    }

    public func retryAfterFailure() async {
        engine.dismissFailure()
        if engine.current.prepares, preparedStep != engine.current.id {
            await prepareCurrentStep()
        } else if case .openAndCheck = engine.current.kind {
            await recheck()
        } else {
            await performPrimary()
        }
    }

    public func cancelWork() {
        work?.cancel()
        engine.cancelWork()
    }

    public func dismissFailure() {
        engine.dismissFailure()
    }

    private func runCurrentStep() async {
        guard engine.startWork() else { return }
        let step = engine.current
        let values = engine.workValues
        let runner = runner
        let task = Task { @MainActor in
            do {
                try await runner(step, values)
                if Task.isCancelled { engine.cancelWork() } else { engine.finishWork(advance: advancesAfterWork) }
            } catch is CancellationError {
                engine.cancelWork()
            } catch {
                engine.fail(classify(error))
            }
        }
        work = task
        await task.value
        work = nil
        await persist()
    }

    private func runAutomaticSteps() async {
        await prepareCurrentStep()
        while engine.phase == .ready, engine.current.isAutomatic {
            let before = engine.index
            await runCurrentStep()
            if engine.index == before { return }
            await prepareCurrentStep()
        }
    }

    private func prepareCurrentStep() async {
        guard let prepare, engine.phase == .ready, engine.current.prepares else { return }
        let step = engine.current
        preparedStep = nil
        guard engine.beginPreparing() else { return }
        do {
            let kind = try await prepare(step)
            guard engine.current.id == step.id, engine.phase == .preparing else { return }
            if let kind { engine.replaceKind(of: step.id, with: kind) }
            preparedStep = step.id
            engine.finishPreparing()
        } catch {
            guard engine.current.id == step.id, engine.phase == .preparing else { return }
            if error is CancellationError { engine.finishPreparing() } else { engine.fail(classify(error)) }
        }
    }

    private func persist() async {
        if engine.isFinished {
            await store.clear(flowID: engine.flowID)
        } else {
            await store.save(engine.progress)
        }
    }
}
