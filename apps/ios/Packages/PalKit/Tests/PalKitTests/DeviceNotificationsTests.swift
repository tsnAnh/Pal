import Foundation
import PalDevice
import PalProtocol
import Synchronization
import Testing

private final class FakeCenter: NotificationCentering {
    struct Added: Equatable {
        var identifier: String
        var title: String
        var subtitle: String
        var body: String
        var sound: Bool
    }

    private struct State {
        var added: [Added] = []
        var removed: [String] = []
    }

    private let state = Mutex(State())
    let failing: Bool

    init(failing: Bool = false) { self.failing = failing }

    var added: [Added] { state.withLock { $0.added } }
    var removed: [String] { state.withLock { $0.removed } }

    func add(identifier: String, title: String, subtitle: String, body: String, sound: Bool) async throws {
        if failing { throw DeviceProviderError.failed("no") }
        state.withLock { $0.added.append(Added(identifier: identifier, title: title, subtitle: subtitle, body: body, sound: sound)) }
    }

    func remove(identifier: String) async {
        state.withLock { $0.removed.append(identifier) }
    }
}

private func makeRig(
    state: DeviceConnectorState = .allowed,
    permission: DeviceOSPermission = .granted,
    center: FakeCenter = FakeCenter()
) async -> (executor: DeviceToolExecutor, center: FakeCenter, permissions: FakePermissions) {
    let ledger = ConnectorLedger(api: FakeConnectorsAPI([.notifications: state]))
    _ = try? await ledger.refresh()
    let permissions = FakePermissions(statuses: [.notifications: permission])
    let executor = DeviceToolExecutor(
        providers: DeviceProviders(notifications: SystemNotifications(center: center)),
        permissions: permissions, ledger: ledger, consent: FakeConsent(),
        environment: DeviceToolEnvironment(deadlineMargin: .zero)
    )
    return (executor, center, permissions)
}

private func call(_ action: String, _ args: JSONValue, profile: String = "Robo") -> DeviceToolRequest {
    DeviceToolRequest(
        requestID: "req-00000001", action: action, connector: DeviceToolAction(rawValue: action)?.connector.rawValue ?? "",
        args: args, profile: profile, deadlineSeconds: 30
    )
}

private func failure(_ outcome: DeviceToolOutcome) -> DeviceToolErrorCode? {
    if case .failure(let code, _) = outcome { return code }
    return nil
}

@Suite struct DeviceNotificationsTests {
    @Test func aPostedNotificationNamesTheBotAndViaPalAndHasNoSoundByDefault() async throws {
        let rig = await makeRig()
        let outcome = await rig.executor.execute(call("notify.post", ["title": "Build done", "body": "All green", "identifier": "build-1"]))
        guard case .success(let value) = outcome else { Issue.record("expected success"); return }
        #expect(value["identifier"]?.stringValue == "build-1")
        let added = try #require(rig.center.added.first)
        #expect(added.title == "Build done" && added.body == "All green")
        #expect(added.subtitle == "Robo via Pal")
        #expect(added.sound == false)
        #expect(added.identifier == "pal.bot.Robo/build-1")
    }

    @Test func aBotSubtitleComesAfterTheAttributionNeverInsteadOfIt() async {
        let rig = await makeRig()
        _ = await rig.executor.execute(call("notify.post", ["title": "t", "body": "b", "subtitle": "Apple Security", "sound": true]))
        #expect(rig.center.added.first?.subtitle == "Robo via Pal · Apple Security")
        #expect(rig.center.added.first?.sound == true)
    }

    @Test func aMissingIdentifierGetsAGeneratedOneAndTheSameOneReplaces() async {
        let rig = await makeRig()
        _ = await rig.executor.execute(call("notify.post", ["title": "t", "body": "b"]))
        _ = await rig.executor.execute(call("notify.post", ["title": "t2", "body": "b", "identifier": "a"]))
        _ = await rig.executor.execute(call("notify.post", ["title": "t3", "body": "b", "identifier": "a"]))
        let ids = rig.center.added.map(\.identifier)
        #expect(ids[0].hasPrefix("pal.bot.Robo/") && ids[0] != ids[1])
        #expect(ids[1] == ids[2])
    }

    @Test func cancelOnlyReachesTheCallingBotsOwnNotifications() async {
        let rig = await makeRig()
        let outcome = await rig.executor.execute(call("notify.cancel", ["identifier": "build-1"]))
        guard case .success = outcome else { Issue.record("expected success"); return }
        #expect(rig.center.removed == ["pal.bot.Robo/build-1"])
        _ = await rig.executor.execute(call("notify.cancel", ["identifier": "build-1"], profile: "Other"))
        #expect(rig.center.removed.last == "pal.bot.Other/build-1")
    }

    @Test func aBotNameCannotImpersonateAnotherThroughControlCharacters() async {
        let rig = await makeRig()
        _ = await rig.executor.execute(call("notify.post", ["title": "t", "body": "b"], profile: "Ro\u{202E}bo\n"))
        #expect(rig.center.added.first?.subtitle == "Robo via Pal")
    }

    @Test(arguments: [
        ["title": String(repeating: "x", count: 81), "body": "b"],
        ["title": "t", "body": String(repeating: "x", count: 241)],
        ["title": "t", "body": "b", "subtitle": String(repeating: "x", count: 81)],
        ["title": "  ", "body": "b"],
        ["title": "t", "body": "b", "identifier": "has space"],
        ["title": "t", "body": "b", "identifier": "a/b"],
    ] as [[String: String]])
    func badTextNeverReachesTheNotificationCenter(args: [String: String]) async {
        let rig = await makeRig()
        let outcome = await rig.executor.execute(call("notify.post", .object(args.mapValues { .string($0) })))
        #expect(failure(outcome) == .invalidArgs)
        #expect(rig.center.added.isEmpty)
    }

    @Test func textAtTheCapsIsAccepted() async {
        let rig = await makeRig()
        let outcome = await rig.executor.execute(call("notify.post", [
            "title": .string(String(repeating: "x", count: 80)), "body": .string(String(repeating: "y", count: 240)),
            "subtitle": .string(String(repeating: "z", count: 80)),
        ]))
        guard case .success = outcome else { Issue.record("expected success"); return }
    }

    @Test func aStoredOffIsIgnored() async {
        let rig = await makeRig(state: .off)
        guard case .success = await rig.executor.execute(call("notify.post", ["title": "t", "body": "b"])) else { Issue.record("expected success"); return }
        #expect(rig.center.added.count == 1)
    }

    @Test func aDeniedMacOSPermissionFailsWithAClearErrorAndNeverAsksAgain() async {
        let rig = await makeRig(permission: .denied)
        let outcome = await rig.executor.execute(call("notify.post", ["title": "t", "body": "b"]))
        #expect(failure(outcome) == .permissionNeeded)
        #expect(rig.center.added.isEmpty)
        #expect(rig.permissions.requested.withLock { $0.isEmpty })
    }

    @Test func thePermissionIsNeverRequestedAtCallTime() async {
        let rig = await makeRig(permission: .notDetermined)
        let outcome = await rig.executor.execute(call("notify.post", ["title": "t", "body": "b"]))
        #expect(failure(outcome) == .permissionNeeded)
        #expect(rig.permissions.requested.withLock { $0.isEmpty })
    }

    @Test func aCenterThatRefusesIsAFailureNotASuccess() async {
        let rig = await makeRig(center: FakeCenter(failing: true))
        let outcome = await rig.executor.execute(call("notify.post", ["title": "t", "body": "b"]))
        #expect(failure(outcome) == .failed)
    }
}
