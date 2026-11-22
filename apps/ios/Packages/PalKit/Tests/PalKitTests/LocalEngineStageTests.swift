import Foundation
import PalLocalEngine
import Testing

@Suite("Local engine installer stages")
struct LocalEngineStageTests {
    private func manifest(_ names: [String], version: Int = 1) -> Data {
        let entries = names.map { "{\"name\":\"\($0)\",\"title\":\"t\",\"category\":\"runtime\",\"needs_user_input\":false}" }
        return Data("{\"protocol_version\":\(version),\"stages\":[\(entries.joined(separator: ","))]}".utf8)
    }

    @Test func theRealStageListMapsOntoTheFiveVisibleSteps() throws {
        let parsed = try InstallManifest.parse(manifest([
            "prerequisites", "repository", "venv", "python-deps", "config", "products", "setup", "gateway", "complete",
        ]))
        #expect(parsed.stages.map(\.step) == [
            .download, .download, .preparePython, .installComponents, .setUp, .installComponents, .setUp, .setUp, .setUp,
        ])
    }

    @Test func aStageTheAppDoesNotKnowStaysWithTheStepBeforeItAndStillRuns() throws {
        let parsed = try InstallManifest.parse(manifest(["prerequisites", "repository", "future-stage"]))
        #expect(parsed.stages.map(\.name) == ["prerequisites", "repository", "future-stage"])
        #expect(parsed.stages.last?.step == .download)
        let leading = try InstallManifest.parse(manifest(["future-stage"]))
        #expect(leading.stages.first?.step == .download)
    }

    @Test func aManifestThatCannotBeTrustedIsRefused() {
        #expect(throws: InstallManifestError.unreadable) { try InstallManifest.parse(Data("not json".utf8)) }
        #expect(throws: InstallManifestError.unreadable) { try InstallManifest.parse(Data("{\"stages\":[]}".utf8)) }
        #expect(throws: InstallManifestError.unsupportedProtocol(2)) { try InstallManifest.parse(manifest(["repository"], version: 2)) }
        #expect(throws: InstallManifestError.empty) { try InstallManifest.parse(manifest([])) }
        #expect(throws: InstallManifestError.duplicateStage("venv")) { try InstallManifest.parse(manifest(["venv", "venv"])) }
    }

    @Test func resumingStartsAtTheNamedStageAndFallsBackToAllStages() throws {
        let parsed = try InstallManifest.parse(manifest(["prerequisites", "repository", "venv"]))
        #expect(parsed.stages(from: "repository").map(\.name) == ["repository", "venv"])
        #expect(parsed.stages(from: nil).count == 3)
        #expect(parsed.stages(from: "missing").count == 3)
    }

    @Test func aStageReportParsesWithAndWithoutAReasonAndSkipFlag() throws {
        let failed = try #require(StageReport.parse(line: "{\"ok\":false,\"stage\":\"repository\",\"skipped\":false,\"reason\":\"git clone failed\"}"))
        #expect(failed == StageReport(ok: false, stage: "repository", skipped: false, reason: "git clone failed"))
        let skipped = try #require(StageReport.parse(line: "{\"ok\":true,\"stage\":\"setup\",\"skipped\":true,\"reason\":\"needs user input\"}"))
        #expect(skipped.ok && skipped.skipped)
        let plain = try #require(StageReport.parse(line: "{\"ok\":true,\"stage\":\"venv\",\"skipped\":false}"))
        #expect(plain.reason == nil)
    }

    @Test func installerNoiseIsNeverMistakenForAReport() {
        #expect(StageReport.parse(line: "→ Cloning into the folder") == nil)
        #expect(StageReport.parse(line: "{\"progress\":0.5}") == nil)
        #expect(StageReport.parse(line: "{\"ok\":tru") == nil)
        #expect(StageReport.parse(line: "") == nil)
    }

    @Test func linesSplitAcrossChunksAreJoinedAndCarriageReturnProgressIsSplit() {
        var splitter = OutputLineSplitter()
        #expect(splitter.feed(Array("{\"ok\":tr".utf8)).isEmpty)
        #expect(splitter.feed(Array("ue,\"stage\":\"venv\"}\nnext".utf8)) == ["{\"ok\":true,\"stage\":\"venv\"}"])
        #expect(splitter.feed(Array(" 10%\rnext 20%\r\n".utf8)) == ["next 10%", "next 20%"])
        #expect(splitter.finish() == nil)
    }

    @Test func aTrailingLineWithoutANewlineIsFlushedAtTheEnd() {
        var splitter = OutputLineSplitter()
        _ = splitter.feed(Array("{\"ok\":true,\"stage\":\"complete\"}".utf8))
        #expect(splitter.finish() == "{\"ok\":true,\"stage\":\"complete\"}")
    }

    @Test func aRunawayLineIsCappedInsteadOfGrowingWithoutBound() {
        var splitter = OutputLineSplitter()
        let lines = splitter.feed([UInt8](repeating: UInt8(ascii: "a"), count: OutputLineSplitter.maxLineBytes * 4) + [UInt8(ascii: "\n")])
        #expect(lines.count == 1)
        #expect(lines[0].utf8.count == OutputLineSplitter.maxLineBytes)
    }
}
