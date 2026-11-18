import Foundation
import Observation

@MainActor
@Observable
public final class StepFlowModel {
    public typealias Runner = @Sendable (FlowStep, [String: String]) async throws -> Void
    public typealias Classifier = @Sendable (any Error) -> SetupStatus

    public private(set) var engine: StepFlowEngine
    public var openPage: @MainActor (URL) -> Void = { _ in }
    public var recovery: (@MainActor (SetupStatus) async -> Void)?

    @ObservationIgnored private let store: any StepFlowProgressStore
    @ObservationIgnored private let runner: Runner
    @ObservationIgnored private let classify: Classifier
    @ObservationIgnored private let advancesAfterWork: Bool
    @ObservationIgnored private var work: Task<Void, Never>?

    public init(
        engine: StepFlowEngine, store: any StepFlowProgressStore = InMemoryStepFlowProgressStore(),
        advancesAfterWork: Bool = true, runner: @escaping Runner = { _, _ in },
        classify: @escaping Classifier = { _ in SetupStatus(code: SetupStatusClass.internalFault.rawValue) }
    ) {
        self.engine = engine
        self.store = store
        self.advancesAfterWork = advancesAfterWork
        self.runner = runner
        self.classify = classify
    }

    public func follow(steps: [FlowStep], at stepID: String, failure: SetupStatus?) {
        if let next = engine.following(steps: steps, at: stepID, failure: failure) { engine = next }
    }

    public func recover(from failure: SetupStatus) async {
        if let recovery {
            await recovery(failure)
            return
        }
        dismissFailure()
        if failure.kind != .vendorRefusedValue { await performPrimary() }
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

    public func performPrimary() async {
        switch engine.primaryAction {
        case .advance:
            if case .instruction(let link?) = engine.current.kind { openPage(link.url) }
            guard engine.advance() else { return }
            await persist()
        case .work:
            await runCurrentStep()
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
        let values = engine.values
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
        while engine.phase == .ready, engine.current.isAutomatic {
            let before = engine.index
            await runCurrentStep()
            if engine.index == before { return }
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
