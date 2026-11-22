import Foundation
import PalLocalEngine
import Testing

@Suite("Local engine errors in product language")
struct LocalEngineFailureTests {
    private let leaks = [
        "/", "~", "launchctl", "launchd", "plist", "python", "uv ", "pip", "git ", "bash", "stdin", "token", "Keychain", "HERMES", "Hermes", "pm ",
    ]

    private func isProductText(_ text: String) -> Bool {
        !text.isEmpty && !leaks.contains { text.contains($0) }
    }

    @Test func everyStartFailureHasAPlainReasonItsOwnCodeAndTheTrace() {
        let failures = [
            EngineFailure.configuration(trace: "t1"), .gatewayInstall(trace: "t1"), .portInUse(trace: "t1"), .loginSetting(trace: "t1"),
            .engineNotResponding(trace: "t1"), .tokenUnavailable(trace: "t1"), .signInFailed(trace: "t1"), .unexpected(trace: "t1"),
            .removalFailed(trace: "t1"), .installerUnavailable(trace: "t1"),
        ]
        for failure in failures {
            #expect(isProductText(failure.reason), "\(failure.code): \(failure.reason)")
            #expect(failure.trace == "t1")
        }
        #expect(Set(failures.map(\.code)).count == failures.count)
        #expect(failures.map(\.code).contains("config_failed") && failures.map(\.code).contains("gateway_install_failed"))
        #expect(failures.map(\.code).contains("port_in_use") && failures.map(\.code).contains("token_unavailable"))
    }

    @Test func eachInstallStepHasItsOwnPlainReasonAndCode() {
        var codes: Set<String> = []
        for stage in [("repository", InstallStep.download), ("venv", .preparePython), ("python-deps", .installComponents), ("config", .setUp)] {
            let failure = EngineFailure.install(stage: InstallStage(name: stage.0, step: stage.1), report: nil, trace: "t")
            #expect(isProductText(failure.reason), "\(failure.reason)")
            #expect(failure.resumeStage == stage.0)
            #expect(failure.step == stage.1)
            codes.insert(failure.code)
        }
        #expect(codes == ["install_download_failed", "install_python_failed", "install_components_failed", "install_setup_failed"])
    }

    @Test func installerReasonTextIsNeverShownOnlyUsedToPickAKnownCause() {
        let stage = InstallStage(name: "prerequisites", step: .download)
        let git = EngineFailure.install(
            stage: stage, report: StageReport(ok: false, stage: "prerequisites", skipped: false, reason: "git is required. /usr/local/bin missing"), trace: "t"
        )
        #expect(git.code == "install_git_missing")
        #expect(!git.reason.contains("/usr"))
        let disk = EngineFailure.install(
            stage: stage,
            report: StageReport(ok: false, stage: "prerequisites", skipped: false, reason: "No space left on device: /Users/x/.hermes"),
            trace: "t"
        )
        #expect(disk.code == "install_disk_full")
        #expect(isProductText(disk.reason))
        let mystery = EngineFailure.install(
            stage: stage, report: StageReport(ok: false, stage: "prerequisites", skipped: false, reason: "Traceback in /Users/x/uv.py"), trace: "t"
        )
        #expect(mystery.code == "install_download_failed")
        #expect(!mystery.reason.contains("Traceback"))
    }

    @Test func titlesFollowTheOperation() {
        #expect(EngineFailure.removalFailed(trace: "t").title == "Couldn't remove Pal")
        #expect(EngineFailure.engineNotResponding(trace: "t").title == "Couldn't start Pal")
        #expect(EngineFailure.installerUnavailable(trace: "t").title == "Couldn't install Pal")
    }

    @Test func aTraceIsTwelveHexCharactersAndDiffersEachTime() {
        let first = EngineFailure.makeTrace()
        let second = EngineFailure.makeTrace()
        #expect(first.count == 12 && first.allSatisfy(\.isHexDigit))
        #expect(first != second)
    }
}
