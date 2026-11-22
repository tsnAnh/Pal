import PalLocalEngine
import Testing

@Suite("Local engine state machine")
struct LocalEngineStateTests {
    private let failure = EngineFailure.install(
        stage: InstallStage(name: "venv", step: .preparePython), report: nil, trace: "abc123"
    )

    private func installing(_ step: InstallStep = .download, completed: Int = 0, total: Int = 6) -> LocalEngineState {
        .installing(InstallProgress(step: step, completedStages: completed, totalStages: total))
    }

    @Test func detectionMapsToTheFiveRestingStates() {
        #expect(LocalEngineState.detecting.reduced(by: .detected(.notInstalled)) == .notInstalled)
        #expect(LocalEngineState.detecting.reduced(by: .detected(.stopped)) == .installed(.stopped))
        #expect(LocalEngineState.detecting.reduced(by: .detected(.running)) == .installed(.running))
        #expect(LocalEngineState.detecting.reduced(by: .detected(.ready)) == .ready)
    }

    @Test func aLateDetectionNeverOverwritesAnInstallOrARemoval() {
        #expect(installing().reduced(by: .detected(.notInstalled)) == installing())
        #expect(LocalEngineState.removing.reduced(by: .detected(.ready)) == .removing)
    }

    @Test func installingFollowsTheStagesAndOnlyMovesForward() {
        var state = LocalEngineState.notInstalled
        state.apply(.installBegan(step: .download, totalStages: 6))
        #expect(state == installing(.download, completed: 0))
        state.apply(.stageBegan(step: .preparePython, completedStages: 2))
        #expect(state == installing(.preparePython, completed: 2))
        state.apply(.stageBegan(step: .download, completedStages: 1))
        #expect(state == installing(.preparePython, completed: 2))
        state.apply(.stageBegan(step: .startPal, completedStages: 5))
        #expect(state == installing(.startPal, completed: 5))
        state.apply(.installSucceeded)
        #expect(state == .ready)
    }

    @Test func aSecondInstallStartIsIgnoredWhileOneRuns() {
        let running = installing(.installComponents, completed: 3)
        #expect(running.reduced(by: .installBegan(step: .download, totalStages: 6)) == running)
    }

    @Test func installCannotStartBeforeDetectionOrOnceReady() {
        #expect(LocalEngineState.detecting.reduced(by: .installBegan(step: .download, totalStages: 6)) == .detecting)
        #expect(LocalEngineState.ready.reduced(by: .installBegan(step: .download, totalStages: 6)) == .ready)
    }

    @Test func aFailureKeepsItsStepAndRetryRestartsFromTheFailedState() {
        var state = installing(.preparePython, completed: 2)
        state.apply(.installFailed(failure))
        #expect(state.failure == failure)
        state.apply(.installBegan(step: .preparePython, totalStages: 5))
        #expect(state == installing(.preparePython, completed: 0, total: 5))
    }

    @Test func cancellingReturnsToWhatIsOnTheMacNotToAFailure() {
        #expect(installing().reduced(by: .installCancelled(.notInstalled)) == .notInstalled)
        #expect(installing(.startPal).reduced(by: .installCancelled(.stopped)) == .installed(.stopped))
    }

    @Test func succeedingOrFailingOutsideAnInstallChangesNothing() {
        #expect(LocalEngineState.notInstalled.reduced(by: .installSucceeded) == .notInstalled)
        #expect(LocalEngineState.ready.reduced(by: .installFailed(failure)) == .ready)
    }

    @Test func removalRunsFromReadyInstalledOrFailedAndEndsNotInstalled() {
        #expect(LocalEngineState.ready.reduced(by: .removalBegan) == .removing)
        #expect(LocalEngineState.installed(.running).reduced(by: .removalBegan) == .removing)
        #expect(LocalEngineState.failed(failure).reduced(by: .removalBegan) == .removing)
        #expect(LocalEngineState.notInstalled.reduced(by: .removalBegan) == .notInstalled)
        #expect(LocalEngineState.removing.reduced(by: .removalSucceeded) == .notInstalled)
        let removalFailure = EngineFailure.removalFailed(trace: "t")
        #expect(LocalEngineState.removing.reduced(by: .removalFailed(removalFailure)) == .failed(removalFailure))
    }

    @Test func aFailedSignInAfterTheEngineRunsIsAFailureYouCanRetry() {
        let signInFailure = EngineFailure.signInFailed(trace: "t")
        #expect(LocalEngineState.ready.reduced(by: .startFailed(signInFailure)) == .failed(signInFailure))
        #expect(installing().reduced(by: .startFailed(signInFailure)) == installing())
        #expect(signInFailure.resumeStage == nil && signInFailure.step == .startPal)
    }

    @Test func progressReportsDoneCurrentAndPendingStepsAndABoundedFraction() {
        let progress = InstallProgress(step: .installComponents, completedStages: 3, totalStages: 6)
        #expect(progress.status(of: .download) == .done)
        #expect(progress.status(of: .preparePython) == .done)
        #expect(progress.status(of: .installComponents) == .current)
        #expect(progress.status(of: .setUp) == .pending)
        #expect(progress.status(of: .startPal) == .pending)
        #expect(progress.fraction == 0.5)
        #expect(InstallProgress(step: .startPal, completedStages: 99, totalStages: 6).fraction == 1)
        #expect(InstallProgress(step: .download, completedStages: 0, totalStages: 0).fraction == 0)
    }

    @Test func onlyDetectingInstallingAndRemovingAreBusy() {
        #expect(LocalEngineState.detecting.isBusy && installing().isBusy && LocalEngineState.removing.isBusy)
        #expect(!LocalEngineState.ready.isBusy && !LocalEngineState.notInstalled.isBusy && !LocalEngineState.failed(failure).isBusy)
    }
}
