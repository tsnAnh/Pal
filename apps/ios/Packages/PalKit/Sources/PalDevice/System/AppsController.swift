import Foundation

public struct WindowSnapshot: Sendable, Equatable {
    public var id: Int
    public var ownerName: String
    public var ownerPID: Int
    public var title: String?
    public var frame: WindowFrameRecord
    public var onScreen: Bool

    public init(id: Int, ownerName: String, ownerPID: Int, title: String?, frame: WindowFrameRecord, onScreen: Bool) {
        self.id = id
        self.ownerName = ownerName
        self.ownerPID = ownerPID
        self.title = title
        self.frame = frame
        self.onScreen = onScreen
    }
}

public protocol AppsWorkspace: Sendable {
    var ownPID: Int { get }
    var canReadTitles: Bool { get }
    var canRaiseWindows: Bool { get }
    func runningApps() -> [AppRecord]
    func installedAppURL(bundleID: String) -> URL?
    func installedAppURL(named name: String) -> URL?
    func open(appAt url: URL, document: URL?) async throws -> AppRecord
    func requestQuit(pid: Int) -> Bool
    func activate(pid: Int) async -> Bool
    func windowSnapshots() -> [WindowSnapshot]
    func raise(windowWithFrame frame: WindowFrameRecord, pid: Int) -> Bool
}

public struct AppsController: AppsProviding {
    private let workspace: any AppsWorkspace

    public init(workspace: any AppsWorkspace) {
        self.workspace = workspace
    }

    public func apps() async throws -> [AppRecord] { workspace.runningApps() }

    public func open(app: String, target: String?) async throws -> AppOpenRecord {
        let running = try matches(app)
        let document = try target.map(documentURL)
        if let existing = running.first, document == nil {
            guard await workspace.activate(pid: existing.pid) else { throw DeviceProviderError.failed("\(existing.name) did not come to the front.") }
            return AppOpenRecord(app: existing, launched: false)
        }
        guard let url = installedURL(running.first?.bundleID ?? app) else { throw DeviceProviderError.notFound }
        do {
            return AppOpenRecord(app: try await workspace.open(appAt: url, document: document), launched: running.isEmpty)
        } catch let error as DeviceProviderError {
            throw error
        } catch {
            throw DeviceProviderError.failed("The app could not be opened.")
        }
    }

    public func quit(app: String) async throws -> AppRecord {
        guard let found = try matches(app).first else { throw DeviceProviderError.notFound }
        guard found.pid != workspace.ownPID else { throw DeviceProviderError.invalidArgs("Pal cannot quit itself.") }
        guard workspace.requestQuit(pid: found.pid) else { throw DeviceProviderError.failed("\(found.name) did not accept the quit request.") }
        return found
    }

    public func windows(app: String?, onScreenOnly: Bool) async throws -> WindowListRecord {
        let pids = try app.map { name -> Set<Int> in
            let found = try matches(name)
            guard !found.isEmpty else { throw DeviceProviderError.notFound }
            return Set(found.map(\.pid))
        }
        let titles = workspace.canReadTitles
        let windows = workspace.windowSnapshots()
            .filter { pids?.contains($0.ownerPID) ?? true }
            .filter { !onScreenOnly || $0.onScreen }
            .map { snapshot in
                let title = titles ? snapshot.title.flatMap { $0.isEmpty ? nil : $0 } : nil
                return WindowRecord(
                    id: snapshot.id, app: snapshot.ownerName, pid: snapshot.ownerPID, title: title,
                    frame: snapshot.frame, onScreen: snapshot.onScreen
                )
            }
        return WindowListRecord(windows: windows, titlesAvailable: titles)
    }

    public func focus(windowID: Int?, app: String?) async throws -> WindowFocusRecord {
        guard let windowID else {
            guard let name = app, let found = try matches(name).first else { throw DeviceProviderError.notFound }
            guard await workspace.activate(pid: found.pid) else { throw DeviceProviderError.failed("\(found.name) did not come to the front.") }
            return WindowFocusRecord(app: found)
        }
        guard let window = workspace.windowSnapshots().first(where: { $0.id == windowID }),
              let owner = workspace.runningApps().first(where: { $0.pid == window.ownerPID })
        else { throw DeviceProviderError.notFound }
        guard await workspace.activate(pid: owner.pid) else { throw DeviceProviderError.failed("\(owner.name) did not come to the front.") }
        guard workspace.canRaiseWindows else {
            return WindowFocusRecord(app: owner, windowID: windowID, note: Self.raiseNote)
        }
        let raised = workspace.raise(windowWithFrame: window.frame, pid: owner.pid)
        return WindowFocusRecord(app: owner, windowID: windowID, raised: raised, note: raised ? nil : "The window could not be raised, so the app was brought to the front.")
    }

    static let raiseNote = "Allow Accessibility for Pal in System Settings > Privacy & Security to raise one window; the app was brought to the front instead."

    private func matches(_ query: String) throws -> [AppRecord] {
        let running = workspace.runningApps()
        let byBundle = running.filter { $0.bundleID?.caseInsensitiveCompare(query) == .orderedSame }
        if !byBundle.isEmpty { return byBundle }
        let byName = running.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame }
        let distinct = Set(byName.map { $0.bundleID ?? String($0.pid) })
        guard distinct.count <= 1 else { throw DeviceProviderError.invalidArgs("More than one running app is named \(query). Use its bundle id.") }
        return byName
    }

    private func installedURL(_ query: String) -> URL? {
        workspace.installedAppURL(bundleID: query) ?? workspace.installedAppURL(named: query)
    }

    private func documentURL(_ text: String) throws -> URL {
        if let url = URL(string: text), url.scheme != nil { return url }
        guard FileManager.default.fileExists(atPath: text) else { throw DeviceProviderError.notFound }
        return URL(fileURLWithPath: text)
    }
}
