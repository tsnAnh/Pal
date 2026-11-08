import Foundation
import HermesDevice
import HermesProtocol
import Synchronization
import Testing

final class FakeConnectorsAPI: DeviceConnectorsAPI {
    private struct State {
        var statuses: [DeviceConnectorID: DeviceConnectorStatus]
        var sets: [(DeviceConnectorID, DeviceConnectorState?, DeviceOSPermission?)] = []
        var lists = 0
    }

    private let state: Mutex<State>

    init(_ states: [DeviceConnectorID: DeviceConnectorState] = [:]) {
        let statuses = Dictionary(uniqueKeysWithValues: DeviceConnectorID.allCases.map { id in
            (id, DeviceConnectorStatus(id: id, title: id.rawValue, subtitle: "", state: states[id] ?? .off, osPermission: .notDetermined))
        })
        state = Mutex(State(statuses: statuses))
    }

    var sets: [(DeviceConnectorID, DeviceConnectorState?, DeviceOSPermission?)] { state.withLock { $0.sets } }
    var listCount: Int { state.withLock { $0.lists } }

    func remoteChange(_ id: DeviceConnectorID, to value: DeviceConnectorState) {
        state.withLock { $0.statuses[id]?.state = value }
    }

    private func result() -> DeviceConnectorsResult {
        state.withLock { stored in
            DeviceConnectorsResult(deviceID: "device-1234", connectors: DeviceConnectorID.allCases.compactMap { stored.statuses[$0] })
        }
    }

    func list() async throws -> DeviceConnectorsResult {
        state.withLock { $0.lists += 1 }
        return result()
    }

    func set(_ id: DeviceConnectorID, state newState: DeviceConnectorState?, osPermission: DeviceOSPermission?) async throws -> DeviceConnectorsResult {
        state.withLock { stored in
            stored.sets.append((id, newState, osPermission))
            if let newState { stored.statuses[id]?.state = newState }
            if let osPermission { stored.statuses[id]?.osPermission = osPermission }
        }
        return result()
    }
}

final class FakePermissions: DevicePermissions {
    let statuses: [DeviceConnectorID: DeviceOSPermission]
    let afterRequest: DeviceOSPermission
    let requested = Mutex<[DeviceConnectorID]>([])

    init(statuses: [DeviceConnectorID: DeviceOSPermission] = [:], afterRequest: DeviceOSPermission = .granted) {
        self.statuses = statuses
        self.afterRequest = afterRequest
    }

    func status(of connector: DeviceConnectorID) async -> DeviceOSPermission {
        if requested.withLock({ $0.contains(connector) }) { return afterRequest }
        return statuses[connector] ?? .granted
    }

    func request(_ connector: DeviceConnectorID) async -> DeviceOSPermission {
        requested.withLock { $0.append(connector) }
        return afterRequest
    }
}

final class FakeConsent: ConsentPrompting {
    let answer: Bool
    let asked = Mutex<[ConsentAsk]>([])

    init(_ answer: Bool) { self.answer = answer }

    func askConsent(_ ask: ConsentAsk) async -> Bool {
        asked.withLock { $0.append(ask) }
        return answer
    }
}

final class FakeDevice: CalendarProviding, RemindersProviding, ContactsProviding, LocationProviding, AlarmsProviding, HomeProviding {
    let calls = Mutex<[String]>([])
    let failure: DeviceProviderError?
    let hang: Bool

    init(failure: DeviceProviderError? = nil, hang: Bool = false) {
        self.failure = failure
        self.hang = hang
    }

    func record(_ name: String) async throws {
        calls.withLock { $0.append(name) }
        if hang { try await Task.sleep(for: .seconds(30)) }
        if let failure { throw failure }
    }

    var callNames: [String] { calls.withLock { $0 } }

    func events(from start: Date, to end: Date, limit: Int) async throws -> [CalendarEventRecord] {
        try await record("calendar.events limit=\(limit)")
        return [CalendarEventRecord(id: "e1", title: "Dentist", start: start.addingTimeInterval(3600), end: start.addingTimeInterval(7200), location: "Main St", calendar: "Home")]
    }

    func add(_ draft: CalendarEventDraft) async throws -> CalendarEventRecord {
        try await record("calendar.add \(draft.title)")
        return CalendarEventRecord(id: "e2", title: draft.title, start: draft.start, end: draft.end, isAllDay: draft.isAllDay)
    }

    func list(named list: String?, includeCompleted: Bool, limit: Int) async throws -> [ReminderRecord] {
        try await record("reminders.list")
        return [ReminderRecord(id: "r1", title: "Call Sam", due: nil, priority: .high)]
    }

    func add(_ draft: ReminderDraft) async throws -> ReminderRecord {
        try await record("reminders.add \(draft.title)")
        return ReminderRecord(id: "r2", title: draft.title, due: draft.due, priority: draft.priority)
    }

    func complete(id: String) async throws -> ReminderRecord {
        try await record("reminders.complete \(id)")
        return ReminderRecord(id: id, title: "Call Sam", isCompleted: true)
    }

    func search(_ query: String, limit: Int) async throws -> [ContactRecord] {
        try await record("contacts.search \(query) limit=\(limit)")
        return [ContactRecord(id: "c1", name: "Sam Rivera", organization: "Acme", phones: (1...8).map { "+1 555 000\($0)" }, emails: ["sam@example.com"])]
    }

    func current(precise: Bool) async throws -> LocationFix {
        try await record("location.current precise=\(precise)")
        return LocationFix(latitude: 10.77, longitude: 106.7, accuracyMeters: 30, place: "District 1", timestamp: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func searchNearby(_ query: String, radiusMeters: Int, limit: Int) async throws -> [PlaceRecord] {
        try await record("location.nearby \(query) r=\(radiusMeters) limit=\(limit)")
        return [PlaceRecord(name: "Cafe", latitude: 10.77, longitude: 106.7, distanceMeters: 120)]
    }

    func setAlarm(at: Date, label: String?, repeatWeekdays: [Weekday]) async throws -> AlarmRecord {
        try await record("alarms.set")
        return AlarmRecord(id: "a1", label: label, at: at, repeatWeekdays: repeatWeekdays)
    }

    func alarms() async throws -> [AlarmRecord] {
        try await record("alarms.list")
        return []
    }

    func startTimer(seconds: Int, label: String?) async throws -> TimerRecord {
        try await record("timers.start \(seconds)")
        return TimerRecord(id: "t1", label: label, seconds: seconds, endsAt: Date(timeIntervalSince1970: 1_800_000_600))
    }

    func accessories(inRoom room: String?) async throws -> [AccessoryRecord] {
        try await record("home.list")
        return [AccessoryRecord(id: "h1", name: "Lamp", room: room, state: ["power": .bool(true)])]
    }

    func set(accessoryID: String, characteristic: HomeCharacteristic, value: JSONValue) async throws -> AccessoryRecord {
        try await record("home.set \(accessoryID) \(characteristic.rawValue)")
        return AccessoryRecord(id: accessoryID, name: "Lamp", state: [characteristic.rawValue: value])
    }
}

private struct Rig {
    let executor: DeviceToolExecutor
    let device: FakeDevice
    let api: FakeConnectorsAPI
    let consent: FakeConsent
    let permissions: FakePermissions
}

private func rig(
    _ states: [DeviceConnectorID: DeviceConnectorState],
    permissions: FakePermissions = FakePermissions(),
    consent: Bool = true,
    failure: DeviceProviderError? = nil,
    hang: Bool = false
) async -> Rig {
    let device = FakeDevice(failure: failure, hang: hang)
    let api = FakeConnectorsAPI(states)
    let ledger = ConnectorLedger(api: api)
    _ = try? await ledger.refresh()
    let fakeConsent = FakeConsent(consent)
    let providers = DeviceProviders(calendar: device, reminders: device, contacts: device, location: device, alarms: device, home: device)
    let executor = DeviceToolExecutor(
        providers: providers, permissions: permissions, ledger: ledger, consent: fakeConsent,
        environment: DeviceToolEnvironment(timeZone: { TimeZone(secondsFromGMT: 7 * 3600)! }, deadlineMargin: .zero)
    )
    return Rig(executor: executor, device: device, api: api, consent: fakeConsent, permissions: permissions)
}

private func request(_ action: String, connector: String? = nil, args: JSONValue = [:], needsConsent: Bool = false, deadline: Int = 30) -> DeviceToolRequest {
    DeviceToolRequest(
        requestID: "req-00000001", action: action,
        connector: connector ?? DeviceToolAction(rawValue: action)?.connector.rawValue ?? String(action.split(separator: ".")[0]),
        args: args, needsConsent: needsConsent, profile: "default", deadlineSeconds: deadline
    )
}

private func failure(_ outcome: DeviceToolOutcome) -> (DeviceToolErrorCode, String)? {
    if case .failure(let code, let message) = outcome { return (code, message) }
    return nil
}

private func result(_ outcome: DeviceToolOutcome) -> JSONValue? {
    if case .success(let value) = outcome { return value }
    return nil
}

@Suite("Device tool capability gating")
struct DeviceToolGatingTests {
    @Test func aDisabledConnectorNeverReachesItsProvider() async {
        let rig = await rig([.contacts: .allowed])
        let outcome = await rig.executor.execute(request("calendar.list_events", args: ["start": "2026-11-08T00:00:00+07:00", "end": "2026-11-09T00:00:00+07:00"]))
        #expect(failure(outcome)?.0 == .consentDeclined)
        #expect(rig.device.callNames.isEmpty)
        #expect(await rig.permissions.requested.withLock { $0 }.isEmpty)
    }

    @Test(arguments: [
        ("calendar.list_events", ["start": JSONValue.string("2026-11-08T00:00:00Z"), "end": "2026-11-09T00:00:00Z"]),
        ("reminders.list", [:]),
        ("contacts.search", ["query": JSONValue.string("Sam")]),
        ("location.current", [:]),
        ("alarms.list", [:]),
        ("home.list_accessories", [:]),
    ])
    func everyConnectorIsRefusedWhenOff(action: String, args: [String: JSONValue]) async {
        let rig = await rig([:])
        let outcome = await rig.executor.execute(request(action, args: .object(args)))
        #expect(failure(outcome)?.0 == .consentDeclined)
        #expect(rig.device.callNames.isEmpty)
    }

    @Test func aStaleOffCacheIsRefreshedBeforeRefusing() async {
        let rig = await rig([.contacts: .off])
        rig.api.remoteChange(.contacts, to: .allowed)
        let outcome = await rig.executor.execute(request("contacts.search", args: ["query": "Sam"]))
        #expect(result(outcome) != nil)
        #expect(rig.api.listCount >= 2)
    }

    @Test func aMismatchedConnectorIsInvalidAndTouchesNothing() async {
        let rig = await rig([.calendar: .allowed, .contacts: .allowed])
        let outcome = await rig.executor.execute(request("contacts.search", connector: "calendar", args: ["query": "Sam"]))
        #expect(failure(outcome)?.0 == .invalidArgs)
        #expect(rig.device.callNames.isEmpty)
    }

    @Test func anUnknownActionIsUnsupported() async {
        let rig = await rig([.calendar: .allowed])
        let outcome = await rig.executor.execute(request("calendar.delete_everything", connector: "calendar"))
        #expect(failure(outcome)?.0 == .unsupported)
        #expect(rig.device.callNames.isEmpty)
    }

    @Test func consentDeclinedStopsBeforeTheOSPromptAndTheProvider() async {
        let rig = await rig([.contacts: .ask], consent: false)
        let outcome = await rig.executor.execute(request("contacts.search", args: ["query": "Sam"], needsConsent: true))
        #expect(failure(outcome)?.0 == .consentDeclined)
        #expect(rig.consent.asked.withLock { $0.count } == 1)
        #expect(rig.device.callNames.isEmpty)
        #expect(rig.permissions.requested.withLock { $0 }.isEmpty)
        #expect(rig.api.sets.isEmpty)
    }

    @Test func consentApprovedPersistsAllowedThenRuns() async {
        let rig = await rig([.contacts: .ask], consent: true)
        let outcome = await rig.executor.execute(request("contacts.search", args: ["query": "Sam"], needsConsent: true))
        #expect(result(outcome) != nil)
        #expect(rig.api.sets.contains { $0.0 == .contacts && $0.1 == .allowed })
        #expect(rig.consent.asked.withLock { $0.first?.action } == .contactsSearch)
    }

    @Test func noConsentPromptWhenTheGatewaySaysConsentIsNotNeeded() async {
        let rig = await rig([.contacts: .allowed])
        _ = await rig.executor.execute(request("contacts.search", args: ["query": "Sam"], needsConsent: false))
        #expect(rig.consent.asked.withLock { $0.isEmpty })
    }

    @Test func undeterminedOSPermissionIsRequestedThenRuns() async {
        let permissions = FakePermissions(statuses: [.contacts: .notDetermined], afterRequest: .granted)
        let rig = await rig([.contacts: .allowed], permissions: permissions)
        let outcome = await rig.executor.execute(request("contacts.search", args: ["query": "Sam"]))
        #expect(result(outcome) != nil)
        #expect(rig.permissions.requested.withLock { $0 } == [.contacts])
    }

    @Test func deniedOSPermissionIsReportedAndNeverReadsData() async {
        let permissions = FakePermissions(statuses: [.contacts: .denied])
        let rig = await rig([.contacts: .allowed], permissions: permissions)
        let outcome = await rig.executor.execute(request("contacts.search", args: ["query": "Sam"]))
        #expect(failure(outcome)?.0 == .permissionDenied)
        #expect(rig.device.callNames.isEmpty)
        #expect(rig.api.sets.contains { $0.0 == .contacts && $0.2 == .denied })
    }

    @Test func aDeniedPromptAnswersPermissionDenied() async {
        let permissions = FakePermissions(statuses: [.location: .notDetermined], afterRequest: .denied)
        let rig = await rig([.location: .allowed], permissions: permissions)
        let outcome = await rig.executor.execute(request("location.current"))
        #expect(failure(outcome)?.0 == .permissionDenied)
        #expect(rig.device.callNames.isEmpty)
    }

    @Test func aConnectorTheDeviceCannotServeIsUnsupported() async {
        let rig = await rig([.home: .allowed], permissions: FakePermissions(statuses: [.home: .unsupported]))
        let outcome = await rig.executor.execute(request("home.list_accessories"))
        #expect(failure(outcome)?.0 == .unsupported)
    }

    @Test func aMissingProviderIsUnsupported() async {
        let ledger = ConnectorLedger(api: FakeConnectorsAPI([.alarms: .allowed]))
        _ = try? await ledger.refresh()
        let executor = DeviceToolExecutor(providers: DeviceProviders(), permissions: FakePermissions(), ledger: ledger, consent: FakeConsent(true))
        let outcome = await executor.execute(request("alarms.list"))
        #expect(failure(outcome)?.0 == .unsupported)
    }
}

private let malformedRequests: [(String, JSONValue)] = [
    ("calendar.list_events", ["start": "not a date", "end": "2026-11-09T00:00:00Z"]),
    ("calendar.list_events", ["start": "2026-11-09T00:00:00Z", "end": "2026-11-08T00:00:00Z"]),
    ("calendar.list_events", [:]),
    ("contacts.search", ["query": "   "]),
    ("reminders.add", ["title": "x", "priority": "urgent"]),
    ("timers.start", ["seconds": 0]),
    ("home.set", ["accessory_id": "h1", "characteristic": "color", "value": 1]),
]

@Suite("Device tool request to response mapping")
struct DeviceToolMappingTests {
    @Test func calendarEventsAreIsoStampedInThePhoneZone() async throws {
        let rig = await rig([.calendar: .allowed])
        let outcome = await rig.executor.execute(request(
            "calendar.list_events", args: ["start": "2026-11-08T00:00:00+07:00", "end": "2026-11-09T00:00:00+07:00", "limit": 500]
        ))
        let event = try #require(result(outcome)?["events"]?[0])
        #expect(event["title"]?.stringValue == "Dentist")
        #expect(event["start"]?.stringValue == "2026-11-08T01:00:00+07:00")
        #expect(event["end"]?.stringValue == "2026-11-08T02:00:00+07:00")
        #expect(event["all_day"]?.boolValue == false)
        #expect(event["location"]?.stringValue == "Main St")
        #expect(rig.device.callNames == ["calendar.events limit=100"])
    }

    @Test func aLocalTimeWithoutOffsetMeansThePhonesZone() async throws {
        let rig = await rig([.calendar: .allowed])
        let outcome = await rig.executor.execute(request("calendar.add_event", args: ["title": "Lunch", "start": "2026-11-08T12:00:00"]))
        let event = try #require(result(outcome)?["event"])
        #expect(event["start"]?.stringValue == "2026-11-08T12:00:00+07:00")
    }

    @Test func contactsAreCappedAtFivePhonesAndEmails() async throws {
        let rig = await rig([.contacts: .allowed])
        let outcome = await rig.executor.execute(request("contacts.search", args: ["query": "Sam", "limit": 3]))
        let contact = try #require(result(outcome)?["contacts"]?[0])
        #expect(contact["phones"]?.arrayValue?.count == 5)
        #expect(contact["name"]?.stringValue == "Sam Rivera")
        #expect(rig.device.callNames == ["contacts.search Sam limit=3"])
    }

    @Test func locationCurrentMapsAccuracyAndPrecision() async throws {
        let rig = await rig([.location: .allowed])
        let outcome = await rig.executor.execute(request("location.current", args: ["accuracy": "precise"]))
        let value = try #require(result(outcome))
        #expect(value["latitude"] != nil)
        #expect(value["accuracy_meters"] != nil)
        #expect(value["place"]?.stringValue == "District 1")
        #expect(rig.device.callNames == ["location.current precise=true"])
    }

    @Test func nearbySearchClampsRadiusAndLimit() async {
        let rig = await rig([.location: .allowed])
        _ = await rig.executor.execute(request("location.search_nearby", args: ["query": "coffee", "radius_meters": 5, "limit": 99]))
        #expect(rig.device.callNames == ["location.nearby coffee r=100 limit=25"])
    }

    @Test func timerAndAlarmResultsCarryTheirShape() async throws {
        let rig = await rig([.alarms: .allowed])
        let timer = await rig.executor.execute(request("timers.start", args: ["seconds": 90, "label": "Tea"]))
        #expect(result(timer)?["timer"]?["seconds"]?.intValue == 90)
        #expect(result(timer)?["timer"]?["ends_at"]?.stringValue?.hasSuffix("+07:00") == true)
        let alarm = await rig.executor.execute(request("alarms.set", args: ["at": "2026-11-09T06:30:00+07:00", "repeat_weekdays": ["mon", "fri"]]))
        #expect(result(alarm)?["alarm"]?["repeat_weekdays"]?.arrayValue?.count == 2)
    }

    @Test func homeSetPassesTheCharacteristicAndValue() async throws {
        let rig = await rig([.home: .allowed])
        let outcome = await rig.executor.execute(request("home.set", args: ["accessory_id": "h1", "characteristic": "brightness", "value": 40]))
        #expect(result(outcome)?["accessory"]?["state"]?["brightness"]?.intValue == 40)
        #expect(rig.device.callNames == ["home.set h1 brightness"])
    }

    @Test(arguments: malformedRequests)
    func malformedArgumentsAreInvalidAndNeverReachTheProvider(action: String, args: JSONValue) async {
        let rig = await rig([.calendar: .allowed, .contacts: .allowed, .reminders: .allowed, .alarms: .allowed, .home: .allowed])
        let outcome = await rig.executor.execute(request(action, args: args))
        #expect(failure(outcome)?.0 == .invalidArgs)
        #expect(rig.device.callNames.isEmpty)
    }

    @Test(arguments: [
        (DeviceProviderError.notFound, DeviceToolErrorCode.notFound),
        (.permissionDenied, .permissionDenied),
        (.unsupported, .unsupported),
        (.invalidArgs("bad"), .invalidArgs),
        (.failed("boom"), .failed),
    ])
    func providerErrorsMapToTheContractCodes(error: DeviceProviderError, code: DeviceToolErrorCode) async {
        let rig = await rig([.reminders: .allowed], failure: error)
        let outcome = await rig.executor.execute(request("reminders.complete", args: ["reminder_id": "r1"]))
        #expect(failure(outcome)?.0 == code)
    }

    @Test func aHungProviderIsCutAtTheDeadline() async {
        let rig = await rig([.reminders: .allowed], hang: true)
        let started = ContinuousClock.now
        let outcome = await rig.executor.execute(request("reminders.list", deadline: 1))
        #expect(failure(outcome)?.0 == .failed)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func failureMessagesAreBoundedToTheWireLimit() {
        let params = DeviceToolOutcome.failure(.failed, String(repeating: "x", count: 1000)).respondParams(requestID: "req-00000001")
        #expect(params["error"]?["message"]?.stringValue?.count == 300)
        #expect(params["ok"]?.boolValue == false)
        #expect(params["error"]?["code"]?.stringValue == "failed")
    }

    @Test func successParamsCarryTheResultObject() {
        let params = DeviceToolOutcome.success(["events": []]).respondParams(requestID: "req-00000001")
        #expect(params["ok"]?.boolValue == true)
        #expect(params["result"]?["events"]?.arrayValue?.isEmpty == true)
        #expect(params["error"] == nil)
    }
}

@Suite("ISO 8601 dates")
struct ISODateTests {
    private let zone = TimeZone(secondsFromGMT: 7 * 3600)!

    @Test(arguments: [
        ("2026-11-08T10:00:00Z", 1_794_132_000.0),
        ("2026-11-08T10:00:00+07:00", 1_794_106_800.0),
        ("2026-11-08T10:00:00.500-05:00", 1_794_150_000.5),
        ("2026-11-08T17:00", 1_794_132_000.0),
        ("2026-11-08", 1_794_070_800.0),
    ])
    func parsesTheFormsTheGatewayAccepts(text: String, expected: Double) {
        #expect(ISODate.parse(text, defaultZone: zone)?.timeIntervalSince1970 == expected)
    }

    @Test(arguments: ["", "yesterday", "2026-13-01T00:00:00Z", "2026-02-30", "2026-11-08T25:00:00Z", "2026-11-08T10:00:00+99:00"])
    func rejectsWhatIsNotADate(text: String) {
        #expect(ISODate.parse(text, defaultZone: zone) == nil)
    }

    @Test func formatsWithTheZoneOffset() {
        let date = Date(timeIntervalSince1970: 1_794_132_000)
        #expect(ISODate.format(date, in: zone) == "2026-11-08T17:00:00+07:00")
        #expect(ISODate.format(date, in: TimeZone(secondsFromGMT: -(5 * 3600 + 1800))!) == "2026-11-08T04:30:00-05:30")
    }
}
