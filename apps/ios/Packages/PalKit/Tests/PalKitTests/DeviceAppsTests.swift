import Foundation
import PalDevice
import PalProtocol
import Synchronization
import Testing

private final class FakeWorkspace: AppsWorkspace {
    private struct Recorded {
        var quit: [Int] = []
        var activated: [Int] = []
        var opened: [(URL, URL?)] = []
        var raised: [Int] = []
    }

    private let recorded = Mutex(Recorded())
    let ownPID = 1
    let canReadTitles: Bool
    let canRaiseWindows: Bool
    let apps: [AppRecord]
    let windows: [WindowSnapshot]
    let installed: [String: URL]
    let raiseSucceeds: Bool

    init(
        titles: Bool = true, raise: Bool = true, raiseSucceeds: Bool = true, apps: [AppRecord] = FakeWorkspace.defaultApps,
        windows: [WindowSnapshot] = FakeWorkspace.defaultWindows, installed: [String: URL] = [:]
    ) {
        canReadTitles = titles
        canRaiseWindows = raise
        self.raiseSucceeds = raiseSucceeds
        self.apps = apps
        self.windows = windows
        self.installed = installed
    }

    static let defaultApps = [
        AppRecord(name: "Pal", bundleID: "dev.tsnanh.pal", pid: 1),
        AppRecord(name: "Safari", bundleID: "com.apple.Safari", pid: 412, frontmost: true),
        AppRecord(name: "Notes", bundleID: "com.apple.Notes", pid: 500),
    ]
    static let defaultWindows = [
        WindowSnapshot(id: 88, ownerName: "Safari", ownerPID: 412, title: "Bank statement", frame: frame, onScreen: true),
        WindowSnapshot(id: 89, ownerName: "Notes", ownerPID: 500, title: "", frame: frame, onScreen: false),
    ]
    static let frame = WindowFrameRecord(x: 0, y: 25, width: 800, height: 600)

    var quitPIDs: [Int] { recorded.withLock { $0.quit } }
    var activatedPIDs: [Int] { recorded.withLock { $0.activated } }
    var openedURLs: [(URL, URL?)] { recorded.withLock { $0.opened } }
    var raisedPIDs: [Int] { recorded.withLock { $0.raised } }

    func runningApps() -> [AppRecord] { apps }
    func installedAppURL(bundleID: String) -> URL? { installed[bundleID] }
    func installedAppURL(named name: String) -> URL? { installed[name] }

    func open(appAt url: URL, document: URL?) async throws -> AppRecord {
        recorded.withLock { $0.opened.append((url, document)) }
        return AppRecord(name: "TextEdit", bundleID: "com.apple.TextEdit", pid: 900, frontmost: true)
    }

    func requestQuit(pid: Int) -> Bool {
        recorded.withLock { $0.quit.append(pid) }
        return true
    }

    func activate(pid: Int) async -> Bool {
        recorded.withLock { $0.activated.append(pid) }
        return true
    }

    func windowSnapshots() -> [WindowSnapshot] { windows }

    func raise(windowWithFrame frame: WindowFrameRecord, pid: Int) -> Bool {
        recorded.withLock { $0.raised.append(pid) }
        return raiseSucceeds
    }
}

private struct AppsRig {
    let executor: DeviceToolExecutor
    let workspace: FakeWorkspace
}

private func appsRig(_ workspace: FakeWorkspace = FakeWorkspace(), state: DeviceConnectorState = .allowed, providers: Bool = true) async -> AppsRig {
    let ledger = ConnectorLedger(api: FakeConnectorsAPI([.apps: state]))
    _ = try? await ledger.refresh()
    let executor = DeviceToolExecutor(
        providers: providers ? DeviceProviders(apps: AppsController(workspace: workspace)) : DeviceProviders(),
        permissions: FakePermissions(), ledger: ledger, consent: FakeConsent(),
        environment: DeviceToolEnvironment(deadlineMargin: .zero)
    )
    return AppsRig(executor: executor, workspace: workspace)
}

private func request(_ action: String, _ args: JSONValue = [:]) -> DeviceToolRequest {
    DeviceToolRequest(
        requestID: "req-00000001", action: action, connector: DeviceToolAction(rawValue: action)?.connector.rawValue ?? "",
        args: args, needsConsent: false, profile: "default", deadlineSeconds: 30
    )
}

private func payload(_ outcome: DeviceToolOutcome) -> JSONValue? {
    if case .success(let value) = outcome { return value }
    return nil
}

private func failure(_ outcome: DeviceToolOutcome) -> (DeviceToolErrorCode, String)? {
    if case .failure(let code, let message) = outcome { return (code, message) }
    return nil
}

private func windowsList(_ value: JSONValue?) -> [JSONValue] {
    guard case .object(let object)? = value, case .array(let list)? = object["windows"] else { return [] }
    return list
}

@Suite struct DeviceAppsTests {
    @Test func listingAppsReturnsNameBundleIdPidAndFrontmost() async throws {
        let rig = await appsRig()
        let result = try #require(payload(await rig.executor.execute(request("apps.list"))))
        guard case .object(let object) = result, case .array(let apps)? = object["apps"] else { Issue.record("no apps"); return }
        #expect(apps.count == 3 && object["truncated"] == .bool(false))
        guard case .object(let safari) = apps[1] else { Issue.record("no object"); return }
        #expect(safari["bundle_id"] == .string("com.apple.Safari") && safari["pid"] == .int(412) && safari["frontmost"] == .bool(true))
    }

    @Test func theAppListIsCappedAndSaysSo() async throws {
        let many = (0..<300).map { AppRecord(name: "App \($0)", bundleID: "x.\($0)", pid: $0 + 10) }
        let rig = await appsRig(FakeWorkspace(apps: many))
        let result = try #require(payload(await rig.executor.execute(request("apps.list"))))
        guard case .object(let object) = result, case .array(let apps)? = object["apps"] else { Issue.record("no apps"); return }
        #expect(apps.count == 200 && object["truncated"] == .bool(true))
    }

    @Test func titlesAreOmittedAndExplainedWithoutScreenRecording() async throws {
        let rig = await appsRig(FakeWorkspace(titles: false))
        let result = try #require(payload(await rig.executor.execute(request("windows.list"))))
        guard case .object(let object) = result else { Issue.record("no object"); return }
        #expect(object["titles_available"] == .bool(false))
        guard case .string(let note)? = object["note"] else { Issue.record("no note"); return }
        #expect(note.contains("Screen Recording"))
        for window in windowsList(result) {
            guard case .object(let fields) = window else { continue }
            #expect(fields["title"] == nil && fields["window_id"] != nil && fields["frame"] != nil)
        }
    }

    @Test func titlesAreReturnedWithScreenRecordingAndEmptyOnesAreDropped() async throws {
        let rig = await appsRig()
        let list = windowsList(payload(await rig.executor.execute(request("windows.list"))))
        guard case .object(let first) = list[0], case .object(let second) = list[1] else { Issue.record("no windows"); return }
        #expect(first["title"] == .string("Bank statement") && second["title"] == nil)
    }

    @Test func windowsCanBeFilteredByAppAndByVisibility() async throws {
        let rig = await appsRig()
        let safari = windowsList(payload(await rig.executor.execute(request("windows.list", ["app": "safari"]))))
        #expect(safari.count == 1)
        let visible = windowsList(payload(await rig.executor.execute(request("windows.list", ["on_screen_only": true]))))
        #expect(visible.count == 1)
        let missing = failure(await rig.executor.execute(request("windows.list", ["app": "Nope"])))
        #expect(missing?.0 == .notFound)
    }

    @Test func quitAsksPolitelyAndNeverQuitsPalItself() async {
        let rig = await appsRig()
        #expect(payload(await rig.executor.execute(request("apps.quit", ["app": "com.apple.Notes"]))) != nil)
        #expect(rig.workspace.quitPIDs == [500])
        #expect(failure(await rig.executor.execute(request("apps.quit", ["app": "Pal"])))?.0 == .invalidArgs)
        #expect(failure(await rig.executor.execute(request("apps.quit", ["app": "Nope"])))?.0 == .notFound)
        #expect(rig.workspace.quitPIDs == [500])
    }

    @Test func openingARunningAppJustBringsItForward() async throws {
        let rig = await appsRig()
        let result = try #require(payload(await rig.executor.execute(request("apps.open", ["app": "Notes"]))))
        guard case .object(let object) = result else { Issue.record("no object"); return }
        #expect(object["launched"] == .bool(false) && rig.workspace.activatedPIDs == [500] && rig.workspace.openedURLs.isEmpty)
    }

    @Test func openingAnInstalledAppLaunchesItWithAFile() async throws {
        let url = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let file = NSTemporaryDirectory() + "apps-test.txt"
        FileManager.default.createFile(atPath: file, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: file) }
        let rig = await appsRig(FakeWorkspace(installed: ["TextEdit": url]))
        let result = try #require(payload(await rig.executor.execute(request("apps.open", ["app": "TextEdit", "target": .string(file)]))))
        guard case .object(let object) = result else { Issue.record("no object"); return }
        #expect(object["launched"] == .bool(true))
        #expect(rig.workspace.openedURLs.first?.0 == url)
        #expect(rig.workspace.openedURLs.first?.1?.lastPathComponent == "apps-test.txt")
    }

    @Test func openingAnUnknownAppOrAnUnsafeTargetFails() async {
        let rig = await appsRig()
        #expect(failure(await rig.executor.execute(request("apps.open", ["app": "Nope"])))?.0 == .notFound)
        let unsafe = failure(await rig.executor.execute(request("apps.open", ["app": "Notes", "target": "ssh://host"])))
        #expect(unsafe?.0 == .invalidArgs && rig.workspace.openedURLs.isEmpty)
    }

    @Test func focusingAWindowRaisesItWhenAccessibilityIsGranted() async throws {
        let rig = await appsRig()
        let result = try #require(payload(await rig.executor.execute(request("windows.focus", ["window_id": 88]))))
        guard case .object(let object) = result else { Issue.record("no object"); return }
        #expect(object["raised"] == .bool(true) && rig.workspace.raisedPIDs == [412] && rig.workspace.activatedPIDs == [412])
    }

    @Test func focusingAWindowFallsBackToTheAppWhenRaisingIsNotPermitted() async throws {
        let rig = await appsRig(FakeWorkspace(raise: false))
        let result = try #require(payload(await rig.executor.execute(request("windows.focus", ["window_id": 88]))))
        guard case .object(let object) = result, case .string(let note)? = object["note"] else { Issue.record("no note"); return }
        #expect(object["raised"] == .bool(false) && note.contains("Accessibility"))
        #expect(rig.workspace.raisedPIDs.isEmpty && rig.workspace.activatedPIDs == [412])
    }

    @Test func focusNeedsAWindowOrAnApp() async {
        let rig = await appsRig()
        #expect(failure(await rig.executor.execute(request("windows.focus")))?.0 == .invalidArgs)
        #expect(failure(await rig.executor.execute(request("windows.focus", ["window_id": 999])))?.0 == .notFound)
    }

    @Test func aStoredOffIsIgnoredAndAMissingProviderRefuses() async {
        let off = await appsRig(state: .off)
        #expect(failure(await off.executor.execute(request("apps.list"))) == nil)
        let none = await appsRig(providers: false)
        #expect(failure(await none.executor.execute(request("apps.list")))?.0 == .unsupported)
    }

    @Test func theConnectorNeedsNoBlockingPermission() {
        #expect(!DeviceConnectorID.apps.needsOSPermission)
        #expect([DeviceToolAction.appsList, .appsOpen, .appsQuit, .windowsList, .windowsFocus].allSatisfy { $0.connector == .apps })
    }
}
