import Foundation
import Observation

@MainActor
@Observable
public final class StepFlowModel {
    public typealias Runner = @Sendable (FlowStep, [String: String]) async throws -> Void
    public typealias Classifier = @Sendable (any Error) -> SetupStatus

    public private(set) var engine: StepFlowEngine
    public var openPage: @MainActor (URL) -> Void = { _ in }

    @ObservationIgnored private let store: any StepFlowProgressStore
    @ObservationIgnored private let runner: Runner
    @ObservationIgnored private let classify: Classifier
    @ObservationIgnored private var work: Task<Void, Never>?

    public init(
        engine: StepFlowEngine, store: any StepFlowProgressStore = InMemoryStepFlowProgressStore(),
        runner: @escaping Runner = { _, _ in },
        classify: @escaping Classifier = { _ in SetupStatus(code: SetupStatusClass.internalFault.rawValue) }
    ) {
        self.engine = engine
        self.store = store
        self.runner = runner
        self.classify = classify
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

    public func replaceSteps(_ steps: [FlowStep]) {
        guard let next = engine.replacingSteps(steps) else { return }
        engine = next
    }

    public func presentFailure(_ status: SetupStatus) {
        engine.presentFailure(status)
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
                if Task.isCancelled { engine.cancelWork() } else { engine.finishWork() }
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
