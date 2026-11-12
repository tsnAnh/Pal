import Foundation
import PalDevice
import PalProtocol
import PalTransport
import Synchronization
import Testing

private final class DeviceGateway: Sendable {
    private let calls = Mutex<[(method: String, params: JSONValue?)]>([])
    private let states: Mutex<[String: String]>

    init(states: [String: String]) {
        self.states = Mutex(states)
    }

    func handle(_ method: String, _ params: JSONValue?, _ connection: Int) -> FakeGateway.Reply {
        calls.withLock { $0.append((method, params)) }
        switch method {
        case "device_connectors.list":
            return .result(statuses())
        case "device_connectors.set":
            if let id = params?["id"]?.stringValue, let state = params?["state"]?.stringValue { states.withLock { $0[id] = state } }
            return .result(statuses())
        case "device.tool.respond":
            return .result(["recorded": true])
        case "gateway.ping":
            return .result(["ok": true])
        default:
            return .failure(RPCError(code: -32601, message: "unknown_method", data: ["reason": "unknown_method"]))
        }
    }

    private func statuses() -> JSONValue {
        let rows: [JSONValue] = DeviceConnectorID.allCases.map { id in
            [
                "id": .string(id.rawValue), "title": .string(id.rawValue.capitalized), "subtitle": "",
                "state": .string(states.withLock { $0[id.rawValue] } ?? "off"), "os_permission": "granted",
            ]
        }
        return ["device_id": "device-1234", "connectors": .array(rows)]
    }

    func responses() -> [JSONValue] {
        calls.withLock { $0.filter { $0.method == "device.tool.respond" }.compactMap(\.params) }
    }
}

private func requestEvent(_ id: String, action: String, connector: String, args: JSONValue = [:]) -> JSONValue {
    [
        "type": "device.tool.request",
        "payload": [
            "request_id": .string(id), "action": .string(action), "connector": .string(connector), "args": args,
            "needs_consent": false, "profile": "default", "deadline_seconds": 20,
        ],
    ]
}

private func eventually(_ timeout: Duration = .seconds(10), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private struct HostRig {
    let gateway: FakeGateway
    let script: DeviceGateway
    let device: FakeDevice
    let stack: DeviceToolStack

    func stop() async {
        await stack.host.stop()
        gateway.stop()
    }
}

private func hostRig(states: [String: String], device: FakeDevice = FakeDevice()) async throws -> HostRig {
    let script = DeviceGateway(states: states)
    let gateway = try await FakeGateway.start { method, params, connection in script.handle(method, params, connection) }
    let url = gateway.url
    let providers = DeviceProviders(calendar: device, reminders: device, contacts: device, location: device, alarms: device, home: device)
    let stack = DeviceToolStack.make(
        connect: { try await GatewayConnection.dial(url: url, ticket: "device-test") },
        providers: providers,
        permissions: FakePermissions(),
        consent: FakeConsent(true),
        environment: DeviceToolEnvironment(deadlineMargin: .zero),
        timing: DeviceToolHostTiming(backoff: [.milliseconds(50)], pingInterval: .seconds(60), callTimeout: .seconds(5), connectWait: .seconds(5))
    )
    await stack.host.start()
    #expect(await eventually { gateway.liveConnectionCount == 1 })
    return HostRig(gateway: gateway, script: script, device: device, stack: stack)
}

@Suite("Device tool host")
struct DeviceToolHostTests {
    @Test func answersARequestOnceWithTheContactsItFound() async throws {
        let rig = try await hostRig(states: ["contacts": "allowed"])
        rig.gateway.push(requestEvent("req-00000001", action: "contacts.search", connector: "contacts", args: ["query": "Sam"]))
        #expect(await eventually { rig.script.responses().count == 1 })
        let response = try #require(rig.script.responses().first)
        #expect(response["request_id"]?.stringValue == "req-00000001")
        #expect(response["ok"]?.boolValue == true)
        #expect(response["result"]?["contacts"]?[0]?["name"]?.stringValue == "Sam Rivera")
        await rig.stop()
    }

    @Test func aRepeatedRequestFrameIsAnsweredExactlyOnce() async throws {
        let rig = try await hostRig(states: ["contacts": "allowed"])
        let event = requestEvent("req-00000002", action: "contacts.search", connector: "contacts", args: ["query": "Sam"])
        rig.gateway.push(event)
        rig.gateway.push(event)
        #expect(await eventually { rig.script.responses().count >= 1 })
        try await Task.sleep(for: .milliseconds(300))
        rig.gateway.push(event)
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.script.responses().count == 1)
        #expect(rig.device.callNames.count == 1)
        await rig.stop()
    }

    @Test func aDisabledConnectorIsAnsweredWithTheContractErrorAndNoData() async throws {
        let rig = try await hostRig(states: ["contacts": "allowed"])
        rig.gateway.push(requestEvent("req-00000003", action: "calendar.list_events", connector: "calendar", args: ["start": "2026-11-08T00:00:00Z", "end": "2026-11-09T00:00:00Z"]))
        #expect(await eventually { rig.script.responses().count == 1 })
        let response = try #require(rig.script.responses().first)
        #expect(response["ok"]?.boolValue == false)
        #expect(response["error"]?["code"]?.stringValue == "consent_declined")
        #expect(response["result"] == nil)
        #expect(rig.device.callNames.isEmpty)
        await rig.stop()
    }

    @Test func aCancelledRequestIsNeverAnswered() async throws {
        let rig = try await hostRig(states: ["reminders": "allowed"], device: FakeDevice(hang: true))
        rig.gateway.push(requestEvent("req-00000004", action: "reminders.list", connector: "reminders"))
        #expect(await eventually { rig.device.callNames.count == 1 })
        rig.gateway.push(["type": "device.tool.cancel", "payload": ["request_id": "req-00000004", "reason": "timeout"]])
        try await Task.sleep(for: .milliseconds(400))
        #expect(rig.script.responses().isEmpty)
        await rig.stop()
    }

    @Test func servesAgainAfterTheSocketDrops() async throws {
        let rig = try await hostRig(states: ["contacts": "allowed"])
        rig.gateway.dropAll()
        #expect(await eventually { rig.gateway.connectionCount >= 2 && rig.gateway.liveConnectionCount == 1 })
        rig.gateway.push(requestEvent("req-00000005", action: "contacts.search", connector: "contacts", args: ["query": "Sam"]))
        #expect(await eventually { rig.script.responses().count == 1 })
        await rig.stop()
    }

    @Test func theLedgerReadsAndChangesConnectorsOverTheSameSocket() async throws {
        let rig = try await hostRig(states: [:])
        let snapshot = try await rig.stack.ledger.refresh()
        #expect(snapshot.count == DeviceConnectorID.allCases.count)
        #expect(await rig.stack.ledger.state(for: .calendar) == .off)
        try await rig.stack.ledger.set(.calendar, state: .allowed)
        #expect(await rig.stack.ledger.state(for: .calendar) == .allowed)
        await rig.stop()
    }
}

@Suite("Device tool wire")
struct DeviceToolWireTests {
    @Test func aRequestEventDecodesEveryContractField() throws {
        let event = GatewayEvent(type: "device.tool.request", payload: [
            "request_id": "abcdef12", "action": "calendar.add_event", "connector": "calendar", "args": ["title": "x"],
            "needs_consent": true, "profile": "alpha", "session_id": "s1", "deadline_seconds": 120,
        ])
        let request = try #require(DeviceToolRequest(event: event))
        #expect(request.needsConsent && request.profile == "alpha" && request.sessionID == "s1" && request.deadlineSeconds == 120)
        #expect(DeviceToolAction(rawValue: request.action)?.connector == .calendar)
    }

    @Test func aFrameWithoutARequestIDIsNotARequest() {
        #expect(DeviceToolRequest(event: GatewayEvent(type: "device.tool.request", payload: ["action": "x", "connector": "y"])) == nil)
        #expect(DeviceToolRequest(event: GatewayEvent(type: "session.info", payload: ["request_id": "abcdef12", "action": "x", "connector": "y"])) == nil)
    }

    @Test func everyActionBelongsToTheConnectorTheGatewayNamesIt() {
        let expected: [String: String] = [
            "calendar.list_events": "calendar", "calendar.add_event": "calendar", "reminders.list": "reminders",
            "reminders.add": "reminders", "reminders.complete": "reminders", "contacts.search": "contacts",
            "location.current": "location", "location.search_nearby": "location", "alarms.set": "alarms",
            "alarms.list": "alarms", "timers.start": "alarms", "home.list_accessories": "home", "home.set": "home",
            "shell.run": "shell", "files.read": "files", "files.list": "files", "files.write": "files",
            "screen.capture": "screen", "screen.read": "screen",
            "apps.list": "apps", "apps.open": "apps", "apps.quit": "apps", "windows.list": "apps", "windows.focus": "apps",
            "clipboard.read": "clipboard", "clipboard.write": "clipboard",
        ]
        #expect(Set(DeviceToolAction.allCases.map(\.rawValue)) == Set(expected.keys))
        for action in DeviceToolAction.allCases { #expect(action.connector.rawValue == expected[action.rawValue]) }
    }

    @Test func unknownStatesAndPermissionsDecodeToTheSafeDefaults() throws {
        let value: JSONValue = [
            "device_id": "device-1234",
            "connectors": [
                ["id": "calendar", "title": "Calendar", "subtitle": "", "state": "mystery", "os_permission": "mystery"],
                ["id": "teleport", "title": "Teleport", "subtitle": "", "state": "allowed", "os_permission": "granted"],
            ],
        ]
        let result = try value.decoded(as: DeviceConnectorsResult.self)
        #expect(result.connectors.count == 1)
        #expect(result.connectors[0].state == .ask && result.connectors[0].osPermission == .notDetermined)
    }
}
