import Foundation
import PalConnect
import Testing

private let intro = FlowStep(
    id: "intro", title: "Set up Google", body: "Five minutes.", kind: .intro(youDo: "Create a client.", palDoes: "Signs you in."), primaryTitle: "Start"
)

private func flow(_ steps: [FlowStep]) -> [FlowStep] { [intro] + steps }

@Suite("Step flow intro and replacement")
struct StepFlowIntroTests {
    static let body = StepFlowEngineTests.steps

    func makeEngine(resume: String? = nil) throws -> StepFlowEngine {
        try #require(
            StepFlowEngine(flowID: "google", steps: flow(Self.body), resume: resume.map { StepFlowProgress(flowID: "google", stepID: $0) })
        )
    }

    @Test func theIntroIsNotARowButShowsStepOneWithRowOneCurrent() throws {
        let engine = try makeEngine()
        #expect(engine.current.id == "intro")
        #expect(engine.stepNumber == 1 && engine.stepCount == 5)
        #expect(engine.checklist.map(\.id).first == "open")
        #expect(engine.checklist.first?.state == .current)
        #expect(engine.primaryAction == .advance && engine.isPrimaryEnabled)
        #expect(!engine.canGoBack)
    }

    @Test func advancingPastTheIntroNeverComesBackToIt() throws {
        var engine = try makeEngine()
        let first = engine.advance()
        #expect(first)
        #expect(engine.current.id == "open")
        #expect(!engine.canGoBack)
        let second = engine.advance()
        #expect(second)
        let back = engine.back()
        #expect(back)
        #expect(engine.current.id == "open")
        let backAgain = engine.back()
        #expect(!backAgain)
    }

    @Test func anIntroAnywhereButFirstIsRefused() {
        #expect(StepFlowEngine(flowID: "x", steps: [StepFlowEngineTests.steps[0], intro, StepFlowEngineTests.steps[6]]) == nil)
        #expect(StepFlowEngine(flowID: "x", steps: [intro, StepFlowEngineTests.steps[6]]) != nil)
    }

    @Test func aRowTitleOverridesTheScreenTitleInTheChecklistOnly() throws {
        var step = StepFlowEngineTests.steps[0]
        step.rowTitle = "Open the console"
        let engine = try #require(StepFlowEngine(flowID: "x", steps: [step, StepFlowEngineTests.steps[6]]))
        #expect(engine.checklist.map(\.title) == ["Open the console"])
        #expect(engine.current.title == "Open Google Cloud")
    }

    @Test func newStepFieldsDefaultToNothing() {
        let step = FlowStep(id: "a", title: "A", kind: .automatic)
        #expect(step.rowTitle == nil && step.note == nil && step.links.isEmpty)
    }

    @Test func replacingStepsKeepsTheCurrentStepSavedValuesAndPhase() throws {
        var engine = try makeEngine(resume: "paste")
        engine.setValue("1234-abc.apps.googleusercontent.com", for: "client_id")
        engine.setValue(fakeClientSecretForTests, for: "secret")
        let started = engine.startWork()
        #expect(started)
        var swapped = flow(Self.body)
        swapped.insert(FlowStep(id: "extra", title: "Extra", kind: .instruction(openPage: nil)), at: 1)
        let next = try #require(engine.replacingSteps(swapped))
        #expect(next.current.id == "paste")
        #expect(next.phase == .working)
        #expect(next.steps.count == engine.steps.count + 1)
        #expect(next.value(for: "client_id") == "1234-abc.apps.googleusercontent.com")
        #expect(next.flowID == "google")
    }

    @Test func replacingStepsFailsWhenTheCurrentStepIsGoneOrTheListIsInvalid() throws {
        let engine = try makeEngine(resume: "copy")
        let withoutCopy = Self.body.filter { $0.id != "copy" }
        #expect(engine.replacingSteps(flow(withoutCopy)) == nil)
        #expect(engine.replacingSteps([]) == nil)
        #expect(engine.replacingSteps(flow(Array(Self.body.dropLast()))) == nil)
    }

    @Test func presentingAFailureShowsItOnAnyStepAndEditingClearsIt() throws {
        var engine = try makeEngine(resume: "paste")
        engine.presentFailure(SetupStatus(code: "offline"))
        #expect(engine.failure?.kind == .offline)
        engine.setValue("x", for: "client_id")
        #expect(engine.failure == nil)
    }

    @Test func presentingAFailureDuringWorkIsIgnored() throws {
        var engine = try makeEngine(resume: "signin")
        let started = engine.startWork()
        #expect(started)
        engine.presentFailure(SetupStatus(code: "offline"))
        #expect(engine.phase == .working)
    }
}

private let fakeClientSecretForTests = "GOCSPX-" + String(repeating: "x", count: 28)

@Suite("Step flow model replacement")
@MainActor
struct StepFlowModelReplacementTests {
    @Test func replacingStepsKeepsTheCurrentStep() throws {
        let engine = try #require(
            StepFlowEngine(flowID: "google", steps: StepFlowEngineTests.steps, resume: StepFlowProgress(flowID: "google", stepID: "copy"))
        )
        let model = StepFlowModel(engine: engine)
        var steps = StepFlowEngineTests.steps
        steps[1].title = "Create the client again"
        model.replaceSteps(steps)
        #expect(model.engine.current.id == "copy")
        #expect(model.engine.current.title == "Create the client again")
        let withoutCopy = steps.filter { $0.id != "copy" }
        model.replaceSteps(withoutCopy)
        #expect(model.engine.current.title == "Create the client again")
    }

    @Test func presentingAFailureShowsItOnTheModel() throws {
        let engine = try #require(StepFlowEngine(flowID: "google", steps: StepFlowEngineTests.steps))
        let model = StepFlowModel(engine: engine)
        model.presentFailure(SetupStatus(code: "gateway_outdated"))
        #expect(model.engine.failure?.kind == .gatewayOutdated)
        model.dismissFailure()
        #expect(model.engine.failure == nil)
    }
}
