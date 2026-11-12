import Foundation
import PalDevice
import PalProtocol
import Synchronization
import Testing

private final class FakeScreenSource: ScreenSource {
    let delay: Duration
    let recognized: String
    let failure: DeviceProviderError?
    private let counts = Mutex((frames: 0, texts: 0))

    init(delay: Duration = .zero, recognized: String = "Inbox", failure: DeviceProviderError? = nil) {
        self.delay = delay
        self.recognized = recognized
        self.failure = failure
    }

    var frames: Int { counts.withLock { $0.frames } }
    var texts: Int { counts.withLock { $0.texts } }

    func frame(display: Int, longEdge: Int, maximumBytes: Int) async throws -> ScreenFrame {
        counts.withLock { $0.frames += 1 }
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        return ScreenFrame(jpeg: Data([0xFF, 0xD8, 0xFF, 0xE0]), width: 1280, height: 800)
    }

    func text(display: Int) async throws -> String {
        counts.withLock { $0.texts += 1 }
        if let failure { throw failure }
        return recognized
    }
}

private final class Stopwatch: Sendable {
    private let instant = Mutex(ContinuousClock.now)

    func advance(_ step: Duration) { instant.withLock { $0 = $0.advanced(by: step) } }
    var now: ContinuousClock.Instant { instant.withLock { $0 } }
}

private final class ActivityLog: Sendable {
    private let events = Mutex<[Bool]>([])

    func record(_ active: Bool) { events.withLock { $0.append(active) } }
    var all: [Bool] { events.withLock { $0 } }
}

private func guarded(_ source: FakeScreenSource, _ watch: Stopwatch, _ log: ActivityLog) -> GuardedScreen {
    GuardedScreen(source: source, now: { watch.now }, activity: { log.record($0) })
}

private func message(of error: any Error) -> String? {
    if case DeviceProviderError.failed(let text) = error { return text }
    return nil
}

@Suite("Screen capture guard")
struct GuardedScreenTests {
    @Test func aCaptureReturnsTheFrameAndOnlyReadsTextWhenAsked() async throws {
        let source = FakeScreenSource()
        let screen = guarded(source, Stopwatch(), ActivityLog())
        let plain = try await screen.capture(display: 1, readText: false)
        #expect(plain.text == nil && plain.width == 1280 && plain.display == 1)
        #expect(source.texts == 0)
        let watch = Stopwatch()
        let withText = guarded(source, watch, ActivityLog())
        let read = try await withText.capture(display: 2, readText: true)
        #expect(read.text == "Inbox" && read.display == 2)
    }

    @Test func recognizedTextIsCapped() async throws {
        let long = String(repeating: "a", count: ScreenLimits.maximumTextCharacters + 500)
        let screen = guarded(FakeScreenSource(recognized: long), Stopwatch(), ActivityLog())
        #expect(try await screen.readText(display: 1).count == ScreenLimits.maximumTextCharacters)
    }

    @Test func theIndicatorIsOnExactlyWhileACaptureRuns() async throws {
        let log = ActivityLog()
        let screen = guarded(FakeScreenSource(), Stopwatch(), log)
        _ = try await screen.capture(display: 1, readText: false)
        #expect(log.all == [true, false])
    }

    @Test func aSecondCaptureWhileOneRunsIsRefused() async throws {
        let source = FakeScreenSource(delay: .milliseconds(300))
        let log = ActivityLog()
        let screen = guarded(source, Stopwatch(), log)
        async let first = screen.capture(display: 1, readText: false)
        try await Task.sleep(for: .milliseconds(60))
        await #expect(throws: DeviceProviderError.self) { try await screen.capture(display: 1, readText: false) }
        _ = try await first
        #expect(source.frames == 1 && log.all == [true, false])
    }

    @Test func captureIsRateLimitedUntilTheIntervalPasses() async throws {
        let watch = Stopwatch()
        let source = FakeScreenSource()
        let screen = guarded(source, watch, ActivityLog())
        _ = try await screen.capture(display: 1, readText: false)
        do {
            _ = try await screen.capture(display: 1, readText: false)
            Issue.record("the second capture should have been refused")
        } catch {
            #expect(message(of: error)?.contains("every 3 seconds") == true)
        }
        #expect(source.frames == 1)
        watch.advance(ScreenLimits.minimumInterval)
        _ = try await screen.capture(display: 1, readText: false)
        #expect(source.frames == 2)
    }

    @Test func aFailedCaptureReleasesTheGuardAndTurnsTheIndicatorOff() async throws {
        let log = ActivityLog()
        let watch = Stopwatch()
        let screen = guarded(FakeScreenSource(failure: .failed("boom")), watch, log)
        await #expect(throws: DeviceProviderError.self) { try await screen.capture(display: 1, readText: false) }
        #expect(log.all == [true, false])
        watch.advance(ScreenLimits.minimumInterval)
        await #expect(throws: DeviceProviderError.self) { try await screen.capture(display: 1, readText: false) }
        #expect(log.all == [true, false, true, false])
    }
}

private struct ScreenRig {
    let executor: DeviceToolExecutor
    let permissions: FakePermissions
    let source: FakeScreenSource
}

private func screenRig(
    state: DeviceConnectorState = .allowed,
    permission: DeviceOSPermission = .granted,
    providers: Bool = true
) async -> ScreenRig {
    let ledger = ConnectorLedger(api: FakeConnectorsAPI([.screen: state]))
    _ = try? await ledger.refresh()
    let source = FakeScreenSource()
    let permissions = FakePermissions(statuses: [.screen: permission])
    let screen = GuardedScreen(source: source)
    let executor = DeviceToolExecutor(
        providers: providers ? DeviceProviders(screen: screen) : DeviceProviders(),
        permissions: permissions, ledger: ledger, consent: FakeConsent(),
        environment: DeviceToolEnvironment(deadlineMargin: .zero)
    )
    return ScreenRig(executor: executor, permissions: permissions, source: source)
}

private func screenCall(_ action: String, args: JSONValue = [:]) -> DeviceToolRequest {
    DeviceToolRequest(
        requestID: "req-00000001", action: action, connector: DeviceToolAction(rawValue: action)?.connector.rawValue ?? "",
        args: args, needsConsent: false, profile: "default", deadlineSeconds: 30
    )
}

@Suite("Screen tools on the executor")
struct DeviceScreenExecutorTests {
    @Test func captureAnswersWithTheImageTheSizeAndTheDisplay() async {
        let rig = await screenRig()
        let outcome = await rig.executor.execute(screenCall("screen.capture", args: ["read_text": true]))
        guard case .success(let result) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(result["image_base64"]?.stringValue == Data([0xFF, 0xD8, 0xFF, 0xE0]).base64EncodedString())
        #expect(result["width"]?.intValue == 1280 && result["height"]?.intValue == 800 && result["display"]?.intValue == 1)
        #expect(result["text"]?.stringValue == "Inbox")
    }

    @Test func readAnswersWithTextOnly() async {
        let rig = await screenRig()
        let outcome = await rig.executor.execute(screenCall("screen.read", args: ["display": 2]))
        guard case .success(let result) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(result["text"]?.stringValue == "Inbox" && result["display"]?.intValue == 2 && result["image_base64"] == nil)
    }

    @Test func aMissingScreenRecordingPermissionFailsClearlyAndNeverPromptsAtCallTime() async {
        for status in [DeviceOSPermission.notDetermined, .denied] {
            let rig = await screenRig(permission: status)
            let outcome = await rig.executor.execute(screenCall("screen.capture"))
            guard case .failure(let code, let text) = outcome else {
                Issue.record("expected failure, got \(outcome)")
                return
            }
            #expect(code == .permissionNeeded && text.contains("Screen Recording"))
            #expect(rig.permissions.requested.withLock { $0 }.isEmpty && rig.source.frames == 0)
        }
    }

    @Test func aStoredOffIsIgnored() async {
        let rig = await screenRig(state: .off)
        guard case .success = await rig.executor.execute(screenCall("screen.capture")) else { Issue.record("expected success"); return }
        #expect(rig.source.frames > 0)
    }

    @Test func aDeviceWithoutAScreenProviderAnswersUnsupported() async {
        let rig = await screenRig(providers: false)
        let outcome = await rig.executor.execute(screenCall("screen.read"))
        guard case .failure(let code, _) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(code == .unsupported)
    }

    @Test func theActionsBelongToScreenAndTheOSPromptIsNotRaisedInline() {
        #expect([DeviceToolAction.screenCapture, .screenRead].allSatisfy { $0.connector == .screen })
        #expect(DeviceConnectorID.screen.needsOSPermission && !DeviceConnectorID.screen.asksOSPermissionOnUse)
        #expect(DeviceConnectorID.calendar.asksOSPermissionOnUse)
    }
}
