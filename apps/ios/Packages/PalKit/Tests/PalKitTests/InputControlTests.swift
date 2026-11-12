import Foundation
import PalDevice
import PalProtocol
import Synchronization
import Testing

private final class FakeSource: InputEventSource {
    struct State {
        var trusted = true
        var locked = false
        var secure = false
        var ownFrontmost = false
        var ownWindow = false
        var failPostAfter: Int?
        var posted: [InputEvent] = []
    }

    let state = Mutex(State())
    let screens = [
        InputDisplayRecord(id: 1, isMain: true, x: 0, y: 0, width: 1000, height: 800, scale: 2),
        InputDisplayRecord(id: 2, isMain: false, x: -500, y: 0, width: 500, height: 400, scale: 1),
    ]

    var isAccessibilityTrusted: Bool { state.withLock { $0.trusted } }
    var isScreenLocked: Bool { state.withLock { $0.locked } }
    var isSecureInputActive: Bool { state.withLock { $0.secure } }
    var isOwnAppFrontmost: Bool { state.withLock { $0.ownFrontmost } }
    func displays() -> [InputDisplayRecord] { screens }
    func pointer() -> (x: Double, y: Double) { (10, 20) }
    func isOwnWindow(atX x: Double, y: Double) -> Bool { state.withLock { $0.ownWindow } }

    func post(_ event: InputEvent) -> Bool {
        state.withLock { state in
            if let limit = state.failPostAfter, state.posted.count >= limit { return false }
            state.posted.append(event)
            return true
        }
    }

    var posted: [InputEvent] { state.withLock { $0.posted } }
    func set(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }
}

private final class ControllerHolder: @unchecked Sendable {
    var controller: InputController?
}

private func controller(_ source: FakeSource) -> InputController {
    InputController(source: source, pause: { _ in })
}

private func failure(_ work: () async throws -> InputPostRecord) async -> DeviceProviderError? {
    do {
        _ = try await work()
        return nil
    } catch let error as DeviceProviderError {
        return error
    } catch {
        return .failed("other")
    }
}

@Suite("Mouse and keyboard control")
struct InputControlTests {
    @Test func aClickMovesThenPressesAndReleasesAtTheDisplayRelativePoint() async throws {
        let source = FakeSource()
        let record = try await controller(source).click(at: InputPoint(x: 5, y: 6, display: 2), button: .right, clicks: 2)
        #expect(record.events == 5)
        #expect(source.posted.first == .mouseMove(x: -495, y: 6))
        #expect(source.posted.last == .mouseUp(x: -495, y: 6, button: .right, clickState: 2))
    }

    @Test func aPointOutsideEveryDisplayOrAnUnknownDisplayIsRefusedWithoutPosting() async {
        let source = FakeSource()
        let input = controller(source)
        #expect(await failure { try await input.move(.absolute(InputPoint(x: 5000, y: 5))) } == .invalidArgs("The point (5000, 5) is outside every display. Call input.displays."))
        #expect(await failure { try await input.click(at: InputPoint(x: 1, y: 1, display: 9), button: .left, clicks: 1) } == .invalidArgs("Display 9 does not exist. Call input.displays."))
        #expect(source.posted.isEmpty)
    }

    @Test func perCallCapsRefuseOversizedInput() async {
        let source = FakeSource()
        let input = controller(source)
        let long = String(repeating: "a", count: InputLimits.maxTypedCharacters + 1)
        #expect(await failure { try await input.type(long) } != nil)
        #expect(await failure { try await input.scroll(at: nil, dx: 0, dy: InputLimits.maxScrollLines + 1) } != nil)
        #expect(await failure { try await input.click(at: nil, button: .left, clicks: 3) } != nil)
        #expect(await failure { try await input.press(key: "notakey") } != nil)
        #expect(source.posted.isEmpty)
    }

    @Test func aFullLengthTextStaysUnderTheEventCap() async throws {
        let source = FakeSource()
        let record = try await controller(source).type(String(repeating: "é", count: InputLimits.maxTypedCharacters))
        #expect(record.events == InputLimits.maxTypedCharacters * 2)
        #expect(record.events <= InputLimits.maxEventsPerCall)
    }

    @Test func aStoppedControllerRefusesEverythingUntilItIsRearmed() async throws {
        let source = FakeSource()
        let input = controller(source)
        input.stop()
        let refused = await failure { try await input.press(key: "return") }
        #expect(refused == .failed(InputController.stoppedMessage))
        #expect(source.posted.isEmpty)
        input.rearm()
        #expect(try await input.press(key: "return").events == 2)
    }

    @Test func stoppingMidActionCutsTheRemainingEventsOff() async {
        let source = FakeSource()
        let holder = ControllerHolder()
        let input = InputController(source: source, pause: { _ in holder.controller?.stop() })
        holder.controller = input
        let outcome = await failure { try await input.type("hello") }
        #expect(outcome == .failed(InputController.stoppedMessage))
        #expect(source.posted.count == 1)
    }

    @Test func missingAccessibilityPermissionIsAPermissionError() async {
        let source = FakeSource()
        source.set { $0.trusted = false }
        #expect(await failure { try await controller(source).press(key: "a") } == .permissionDenied)
        #expect(source.posted.isEmpty)
    }

    @Test func aLockedScreenSendsNothing() async {
        let source = FakeSource()
        source.set { $0.locked = true }
        let outcome = await failure { try await controller(source).click(at: nil, button: .left, clicks: 1) }
        #expect(outcome == .failed("The screen is locked or the login window is showing, so no input was sent."))
        #expect(source.posted.isEmpty)
    }

    @Test func secureInputIsReportedAndNothingIsTyped() async {
        let source = FakeSource()
        source.set { $0.secure = true }
        let input = controller(source)
        for work in [{ try await input.type("secret") }, { try await input.press(key: "cmd+v") }] {
            guard case .failed(let message)? = await failure(work) else { Issue.record("expected a failure"); return }
            #expect(message.contains("Secure input is on") && message.contains("Do not retry"))
        }
        #expect(source.posted.isEmpty)
    }

    @Test func theAppRefusesToControlItsOwnWindows() async {
        let source = FakeSource()
        source.set { $0.ownWindow = true }
        let input = controller(source)
        #expect(await failure { try await input.click(at: InputPoint(x: 10, y: 10), button: .left, clicks: 1) } != nil)
        #expect(await failure { try await input.drag(from: InputPoint(x: 1, y: 1), to: InputPoint(x: 9, y: 9), button: .left) } != nil)
        source.set { $0.ownWindow = false; $0.ownFrontmost = true }
        #expect(await failure { try await input.type("hi") } != nil)
        #expect(source.posted.isEmpty)
    }

    @Test func anEventThatCannotBePostedIsNeverReportedAsSuccess() async {
        let source = FakeSource()
        source.set { $0.failPostAfter = 1 }
        let outcome = await failure { try await controller(source).click(at: nil, button: .left, clicks: 1) }
        #expect(outcome == .failed("The event could not be posted; 1 of 2 events went out."))
    }

    @Test func comboKeysParseToTheKeyAndItsModifiers() {
        #expect(InputKeyMap.parse("cmd+c") == InputKeyChord(code: 8, modifiers: .command))
        #expect(InputKeyMap.parse("Cmd+Shift+4") == InputKeyChord(code: 21, modifiers: [.command, .shift]))
        #expect(InputKeyMap.parse("escape") == InputKeyChord(code: 53, modifiers: []))
        #expect(InputKeyMap.parse("cmd+") == InputKeyChord(code: 24, modifiers: .command))
        #expect(InputKeyMap.parse("hyper+c") == nil)
        #expect(InputKeyMap.parse("") == nil)
    }

    @Test func threeQuickEscapePressesTripTheKillGestureAndSlowOnesDoNot() {
        var detector = EscapeBurstDetector()
        #expect(!detector.record(at: 0) && !detector.record(at: 0.4) && detector.record(at: 0.9))
        #expect(!detector.record(at: 10) && !detector.record(at: 12) && !detector.record(at: 14))
    }

    @Test func theExecutorRefusesInputWithoutAccessibilityAndNeverAsksForItAtCallTime() async {
        let api = FakeConnectorsAPI([.input: .allowed])
        let ledger = ConnectorLedger(api: api)
        _ = try? await ledger.refresh()
        let source = FakeSource()
        let permissions = FakePermissions(statuses: [.input: .notDetermined])
        let executor = DeviceToolExecutor(
            providers: DeviceProviders(input: controller(source)), permissions: permissions, ledger: ledger,
            consent: FakeConsent(true), environment: DeviceToolEnvironment(deadlineMargin: .zero)
        )
        let outcome = await executor.execute(DeviceToolRequest(
            requestID: "req-00000001", action: "input.key", connector: "input", args: ["key": "return"]
        ))
        guard case .failure(let code, let message) = outcome else { Issue.record("expected a failure"); return }
        #expect(code == .permissionDenied && message.contains("Accessibility"))
        #expect(permissions.requested.withLock { $0.isEmpty })
        #expect(source.posted.isEmpty)
    }

    @Test func theExecutorRunsAnInputActionAndReturnsAShortResult() async throws {
        let api = FakeConnectorsAPI([.input: .allowed])
        let ledger = ConnectorLedger(api: api)
        _ = try? await ledger.refresh()
        let executor = DeviceToolExecutor(
            providers: DeviceProviders(input: controller(FakeSource())), permissions: FakePermissions(), ledger: ledger,
            consent: FakeConsent(true), environment: DeviceToolEnvironment(deadlineMargin: .zero)
        )
        let outcome = await executor.execute(DeviceToolRequest(
            requestID: "req-00000002", action: "input.click", connector: "input", args: ["x": 10, "y": 10, "display": 1]
        ))
        guard case .success(let result) = outcome else { Issue.record("expected success"); return }
        #expect(result["events"]?.intValue == 3)
        let displays = await executor.execute(DeviceToolRequest(requestID: "req-00000003", action: "input.displays", connector: "input"))
        guard case .success(let shown) = displays else { Issue.record("expected success"); return }
        #expect(shown["pointer_x"]?.intValue == 10)
    }

    @Test func anOlderPalWithoutInputAnswersUnsupported() async {
        let api = FakeConnectorsAPI([.input: .allowed])
        let ledger = ConnectorLedger(api: api)
        _ = try? await ledger.refresh()
        let executor = DeviceToolExecutor(
            providers: DeviceProviders(), permissions: FakePermissions(), ledger: ledger, consent: FakeConsent(true),
            environment: DeviceToolEnvironment(deadlineMargin: .zero)
        )
        let outcome = await executor.execute(DeviceToolRequest(
            requestID: "req-00000004", action: "input.click", connector: "input", args: ["x": 1, "y": 1]
        ))
        guard case .failure(let code, _) = outcome else { Issue.record("expected a failure"); return }
        #expect(code == .unsupported)
    }
}
