import Foundation
import PalConnect
import Testing

private let fakeClientSecret = "GOCSPX-" + String(repeating: "x", count: 28)

@Suite("Step flow engine")
struct StepFlowEngineTests {
    static let secret = SetupField(id: "secret", label: "Client secret", secret: true, prefixes: ["GOCSPX-"])
    static let clientID = SetupField(id: "client_id", label: "Client ID", suffix: ".apps.googleusercontent.com")

    static let steps: [FlowStep] = [
        FlowStep(
            id: "open", title: "Open Google Cloud",
            kind: .instruction(openPage: SetupLink(label: "Open Google Cloud", url: URL(string: "https://console.cloud.google.com")!)),
            skipTitle: "I already have one", skipTarget: "paste"
        ),
        FlowStep(id: "copy", title: "Create the client", kind: .copyCard(copies: [SetupCopy(label: "Redirect address", value: "https://pal.example/cb")])),
        FlowStep(id: "paste", title: "Paste id and secret", kind: .paste(fields: [clientID, secret]), primaryTitle: "Check and save"),
        FlowStep(id: "prepare", title: "Pal prepares sign-in", kind: .automatic),
        FlowStep(id: "signin", title: "Sign in", kind: .browserRoundTrip(waitingTitle: "Waiting for Google", waitingBody: "Finish in the browser.")),
        FlowStep(id: "wait", title: "Waiting", kind: .waiting(title: "Waiting for approval", body: "Pal keeps going.")),
        FlowStep(id: "done", title: "Connected", kind: .success(title: "Connected", body: "All set.")),
    ]

    func makeEngine(resume: StepFlowProgress? = nil) throws -> StepFlowEngine {
        try #require(StepFlowEngine(flowID: "google", steps: Self.steps, resume: resume))
    }

    @Test func startsAtTheFirstStepWithTheChecklistFromData() throws {
        let engine = try makeEngine()
        #expect(engine.current.id == "open")
        #expect(engine.stepCount == 5)
        #expect(engine.stepNumber == 1)
        #expect(engine.checklist.map(\.title) == ["Open Google Cloud", "Create the client", "Paste id and secret", "Pal prepares sign-in", "Sign in"])
        #expect(engine.checklist.map(\.state) == [.current, .upcoming, .upcoming, .upcoming, .upcoming])
        #expect(engine.checklist.map(\.isAutomatic) == [false, false, false, true, false])
        #expect(!engine.canGoBack)
    }

    @Test func advancesForwardThenBack() throws {
        var engine = try makeEngine()
        let moved1 = engine.advance()
        #expect(moved1)
        #expect(engine.current.id == "copy")
        #expect(engine.checklist.first?.state == .done)
        #expect(engine.canGoBack)
        let moved2 = engine.back()
        #expect(moved2)
        #expect(engine.current.id == "open")
        let moved3 = engine.back()
        #expect(!moved3)
    }

    @Test func aStepThatWorksCannotBeAdvancedWithAdvance() throws {
        var engine = try makeEngine(resume: StepFlowProgress(flowID: "google", stepID: "paste"))
        let moved4 = engine.advance()
        #expect(!moved4)
        #expect(engine.current.id == "paste")
    }

    @Test func resumesAtTheSavedStep() throws {
        let engine = try makeEngine(resume: StepFlowProgress(flowID: "google", stepID: "paste", saved: ["client_id", "ghost"]))
        #expect(engine.current.id == "paste")
        #expect(engine.stepNumber == 3)
        #expect(engine.checklist.map(\.state) == [.done, .done, .current, .upcoming, .upcoming])
        #expect(engine.progress.saved == ["client_id"])
    }

    @Test func resumeNeverLandsOnSuccessOrAnUnknownStep() throws {
        #expect(try makeEngine(resume: StepFlowProgress(flowID: "google", stepID: "done")).current.id == "wait")
        #expect(try makeEngine(resume: StepFlowProgress(flowID: "google", stepID: "missing")).current.id == "open")
    }

    @Test func skipJumpsToTheTargetAndMarksEarlierRowsDone() throws {
        var engine = try makeEngine()
        #expect(engine.canSkip)
        let moved5 = engine.skip()
        #expect(moved5)
        #expect(engine.current.id == "paste")
        #expect(engine.checklist.map(\.state).prefix(3) == [.done, .done, .current])
        #expect(!engine.canSkip)
    }

    @Test func invalidFieldsBlockThePrimaryActionUntilEveryFieldIsValid() throws {
        var engine = try makeEngine(resume: StepFlowProgress(flowID: "google", stepID: "paste"))
        #expect(!engine.isPrimaryEnabled)
        let moved6 = engine.startWork()
        #expect(!moved6)
        engine.setValue("1234-abc.apps.googleusercontent.com", for: "client_id")
        engine.setValue("abc123", for: "secret")
        #expect(engine.shape(of: "client_id") == .valid)
        #expect(engine.shape(of: "secret") == .wrongStart(["GOCSPX-"]))
        #expect(!engine.isPrimaryEnabled)
        engine.setValue(fakeClientSecret, for: "secret")
        #expect(engine.isPrimaryEnabled)
        let moved7 = engine.startWork()
        #expect(moved7)
        #expect(engine.phase == .working)
        #expect(!engine.isPrimaryEnabled)
    }

    struct ShapeCase: Sendable {
        let shape: SetupFieldShape
        let label: String
        let message: String?
    }

    @Test(arguments: [
        ShapeCase(shape: .empty, label: "Client secret", message: nil),
        ShapeCase(shape: .valid, label: "Client ID", message: "Looks right"),
        ShapeCase(
            shape: .wrongStart(["GOCSPX-"]), label: "Client secret",
            message: "That is not a client secret. It starts with GOCSPX-. Copy it again."
        ),
        ShapeCase(
            shape: .wrongStart(["ghp_", "github_pat_"]), label: "Token",
            message: "That is not a token. It starts with ghp_ or github_pat_. Copy it again."
        ),
        ShapeCase(
            shape: .wrongEnd(".apps.googleusercontent.com"), label: "Client ID",
            message: "That is not a client ID. It ends with .apps.googleusercontent.com. Copy it again."
        ),
        ShapeCase(shape: .hasSpaces, label: "Client secret", message: "The client secret can't contain spaces. Paste it again without them."),
    ])
    func fieldProblemsReadAsPlainSentencesWithTheExpectedShape(_ test: ShapeCase) {
        #expect(test.shape.message(label: test.label) == test.message)
    }

    @Test func aSpaceInAFieldIsReportedAsSuch() throws {
        var engine = try makeEngine(resume: StepFlowProgress(flowID: "google", stepID: "paste"))
        engine.setValue("GOCSPX- abc", for: "secret")
        #expect(engine.shape(of: "secret") == .hasSpaces)
    }

    @Test func finishedWorkKeepsSavedFieldIdsAndDropsTheValues() throws {
        var engine = try makeEngine(resume: StepFlowProgress(flowID: "google", stepID: "paste"))
        engine.setValue("1234-abc.apps.googleusercontent.com", for: "client_id")
        engine.setValue(fakeClientSecret, for: "secret")
        let moved8 = engine.startWork()
        #expect(moved8)
        engine.finishWork()
        #expect(engine.current.id == "prepare")
        #expect(engine.value(for: "secret").isEmpty)
        #expect(engine.progress == StepFlowProgress(flowID: "google", stepID: "prepare", saved: ["client_id", "secret"]))
    }

    @Test func automaticStepsRunWithoutAPrimaryActionAndAreSkippedByBack() throws {
        var engine = try makeEngine(resume: StepFlowProgress(flowID: "google", stepID: "prepare"))
        #expect(engine.primaryAction == .none)
        #expect(!engine.isPrimaryEnabled)
        let moved9 = engine.startWork()
        #expect(moved9)
        engine.finishWork()
        #expect(engine.current.id == "signin")
        let moved10 = engine.back()
        #expect(moved10)
        #expect(engine.current.id == "paste")
    }

    @Test func aFailureIsKeptUntilTheOwnerEditsOrDismisses() throws {
        var engine = try makeEngine(resume: StepFlowProgress(flowID: "google", stepID: "signin"))
        let moved11 = engine.startWork()
        #expect(moved11)
        engine.fail(SetupStatus(code: "needs_reauth", subject: "Google"))
        #expect(engine.failure?.kind == .needsReauth)
        #expect(engine.isPrimaryEnabled)
        #expect(engine.canGoBack)
        engine.dismissFailure()
        #expect(engine.failure == nil)
        #expect(engine.phase == .ready)
    }

    @Test func cancelingWorkReturnsToTheSameStep() throws {
        var engine = try makeEngine(resume: StepFlowProgress(flowID: "google", stepID: "signin"))
        let moved12 = engine.startWork()
        #expect(moved12)
        #expect(!engine.canGoBack)
        engine.cancelWork()
        #expect(engine.phase == .ready)
        #expect(engine.current.id == "signin")
    }

    @Test func theWaitingScreenKeepsTheLastRowCurrent() throws {
        var engine = try makeEngine(resume: StepFlowProgress(flowID: "google", stepID: "signin"))
        let moved13 = engine.startWork()
        #expect(moved13)
        engine.finishWork()
        #expect(engine.current.id == "wait")
        #expect(engine.stepNumber == 5)
        #expect(engine.primaryAction == .none)
    }

    @Test func rejectsFlowsWithoutAFinalSuccessOrWithRepeatedIds() {
        #expect(StepFlowEngine(flowID: "x", steps: []) == nil)
        #expect(StepFlowEngine(flowID: "x", steps: [Self.steps[0]]) == nil)
        #expect(StepFlowEngine(flowID: "x", steps: [Self.steps[0], Self.steps[0], Self.steps[6]]) == nil)
        #expect(StepFlowEngine(flowID: "x", steps: [Self.steps[6], Self.steps[6]]) == nil)
    }
}

@Suite("Step flow model")
@MainActor
struct StepFlowModelTests {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func record(_ id: String) { lock.lock(); ids.append(id); lock.unlock() }
        var recorded: [String] { lock.lock(); defer { lock.unlock() }; return ids }
    }

    struct Boom: Error {}

    func makeModel(
        resume: String = "open", store: any StepFlowProgressStore = InMemoryStepFlowProgressStore(),
        calls: Calls = Calls(), failing: Set<String> = []
    ) throws -> StepFlowModel {
        let engine = try #require(
            StepFlowEngine(flowID: "google", steps: StepFlowEngineTests.steps, resume: StepFlowProgress(flowID: "google", stepID: resume))
        )
        return StepFlowModel(
            engine: engine, store: store,
            runner: { step, _ in
                calls.record(step.id)
                if failing.contains(step.id) { throw Boom() }
            },
            classify: { _ in SetupStatus(code: "offline") }
        )
    }

    @Test func advancingSavesProgressAndOpensThePage() async throws {
        let store = InMemoryStepFlowProgressStore()
        let model = try makeModel(store: store)
        var opened: [URL] = []
        model.openPage = { opened.append($0) }
        await model.performPrimary()
        #expect(opened.map(\.host) == ["console.cloud.google.com"])
        #expect(model.engine.current.id == "copy")
        #expect(await store.load(flowID: "google")?.stepID == "copy")
    }

    @Test func aWorkStepRunsThenAutomaticStepsRunOnTheirOwn() async throws {
        let calls = Calls()
        let model = try makeModel(resume: "paste", calls: calls)
        model.setValue("1234-abc.apps.googleusercontent.com", for: "client_id")
        model.setValue(fakeClientSecret, for: "secret")
        await model.performPrimary()
        #expect(calls.recorded == ["paste", "prepare"])
        #expect(model.engine.current.id == "signin")
    }

    @Test func aFailedStepShowsTheMappedStatusAndStaysPut() async throws {
        let model = try makeModel(resume: "signin", failing: ["signin"])
        await model.performPrimary()
        #expect(model.engine.current.id == "signin")
        #expect(model.engine.failure?.kind == .offline)
    }

    @Test func aFailedAutomaticStepRunsAgainOnRetry() async throws {
        let calls = Calls()
        let attempts = Calls()
        let engine = try #require(
            StepFlowEngine(flowID: "google", steps: StepFlowEngineTests.steps, resume: StepFlowProgress(flowID: "google", stepID: "prepare"))
        )
        let model = StepFlowModel(
            engine: engine,
            runner: { step, _ in
                calls.record(step.id)
                if step.id == "prepare", attempts.recorded.isEmpty {
                    attempts.record("prepare")
                    throw Boom()
                }
            },
            classify: { _ in SetupStatus(code: "offline") }
        )
        await model.start()
        #expect(model.engine.current.id == "prepare")
        #expect(model.engine.failure?.kind == .offline)
        model.dismissFailure()
        await model.performPrimary()
        #expect(calls.recorded == ["prepare", "prepare"])
        #expect(model.engine.current.id == "signin")
    }

    @Test func finishingTheFlowClearsTheSavedProgress() async throws {
        let store = InMemoryStepFlowProgressStore()
        await store.save(StepFlowProgress(flowID: "token", stepID: "signin"))
        let steps = [
            FlowStep(id: "signin", title: "Sign in", kind: .browserRoundTrip(waitingTitle: "Waiting", waitingBody: "")),
            FlowStep(id: "done", title: "Done", kind: .success(title: "Connected", body: "")),
        ]
        let engine = try #require(StepFlowEngine(flowID: "token", steps: steps))
        let model = StepFlowModel(engine: engine, store: store)
        await model.performPrimary()
        #expect(model.engine.isFinished)
        #expect(await store.load(flowID: "token") == nil)
    }

    @Test func restoreResumesFromTheStoreOnAnotherDevice() async throws {
        let store = InMemoryStepFlowProgressStore()
        await store.save(StepFlowProgress(flowID: "google", stepID: "paste", saved: ["client_id"]))
        let model = try makeModel(store: store)
        await model.start()
        #expect(model.engine.current.id == "paste")
    }

    @Test func goingBackAndSkippingSaveProgress() async throws {
        let store = InMemoryStepFlowProgressStore()
        let model = try makeModel(store: store)
        await model.skip()
        #expect(await store.load(flowID: "google")?.stepID == "paste")
        await model.back()
        #expect(await store.load(flowID: "google")?.stepID == "copy")
    }

    @Test func aRefusedRewindKeepsTheCurrentStepAndAnAcceptedOneMovesBack() async throws {
        let model = try makeModel(resume: "paste")
        var asked: [String] = []
        var accept = false
        model.rewind = { from, to in
            asked.append("\(from.id)>\(to.id)")
            return accept
        }
        await model.back()
        #expect(model.engine.current.id == "paste")
        accept = true
        await model.back()
        #expect(model.engine.current.id == "copy")
        #expect(asked == ["paste>copy", "paste>copy"])
    }

    @Test func aRewindThatAlreadyMovedTheFlowBackDoesNotMoveItFurther() async throws {
        let model = try makeModel(resume: "paste")
        model.rewind = { [unowned model] _, to in
            model.follow(steps: StepFlowEngineTests.steps, at: to.id, failure: nil)
            return true
        }
        await model.back()
        #expect(model.engine.current.id == "copy")
    }

    @Test func aCancelledRunnerLeavesTheStepWithoutAdvancing() async throws {
        let resume = StepFlowProgress(flowID: "google", stepID: "prepare")
        let engine = try #require(StepFlowEngine(flowID: "google", steps: StepFlowEngineTests.steps, resume: resume))
        let model = StepFlowModel(engine: engine, runner: { _, _ in throw CancellationError() })
        await model.start()
        #expect(model.engine.current.id == "prepare")
        #expect(model.engine.phase == .ready)
    }
}
