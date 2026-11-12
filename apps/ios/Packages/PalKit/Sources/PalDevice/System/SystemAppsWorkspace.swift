#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics

enum AppsSystemAccess {
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    static func requestAccessibility() {
        let prompt = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }
}

struct SystemAppsWorkspace: AppsWorkspace {
    private static let searchFolders = [
        "/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    var ownPID: Int { Int(ProcessInfo.processInfo.processIdentifier) }
    var canReadTitles: Bool { AppsSystemAccess.screenRecordingGranted }
    var canRaiseWindows: Bool { AppsSystemAccess.accessibilityGranted }

    func runningApps() -> [AppRecord] {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let records = NSWorkspace.shared.runningApplications.map { app in
            (regular: app.activationPolicy == .regular, record: AppRecord(
                name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "Unknown",
                bundleID: app.bundleIdentifier, pid: Int(app.processIdentifier), frontmost: app.processIdentifier == front
            ))
        }
        let ordered = records.sorted {
            if $0.regular != $1.regular { return $0.regular }
            return $0.record.name.localizedCaseInsensitiveCompare($1.record.name) == .orderedAscending
        }
        return ordered.map(\.record)
    }

    func installedAppURL(bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    func installedAppURL(named name: String) -> URL? {
        let file = name.lowercased().hasSuffix(".app") ? name : name + ".app"
        guard !file.contains("/") else { return nil }
        return Self.searchFolders
            .map { URL(fileURLWithPath: $0).appendingPathComponent(file) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func open(appAt url: URL, document: URL?) async throws -> AppRecord {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let running: NSRunningApplication
        if let document {
            running = try await NSWorkspace.shared.open([document], withApplicationAt: url, configuration: configuration)
        } else {
            running = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        return AppRecord(
            name: running.localizedName ?? url.deletingPathExtension().lastPathComponent, bundleID: running.bundleIdentifier,
            pid: Int(running.processIdentifier), frontmost: running.isActive
        )
    }

    func requestQuit(pid: Int) -> Bool {
        NSRunningApplication(processIdentifier: pid_t(pid))?.terminate() ?? false
    }

    func activate(pid: Int) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else { return false }
        if app.isHidden { app.unhide() }
        guard let url = app.bundleURL else { return app.activate() }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return (try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)) != nil
    }

    func windowSnapshots() -> [WindowSnapshot] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let rows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row[kCGWindowNumber as String] as? Int, let pid = row[kCGWindowOwnerPID as String] as? Int,
                  (row[kCGWindowLayer as String] as? Int) == 0,
                  let owner = row[kCGWindowOwnerName as String] as? String,
                  let bounds = row[kCGWindowBounds as String] as? [String: Double],
                  let frame = Self.frame(bounds), frame.width > 0, frame.height > 0
            else { return nil }
            return WindowSnapshot(
                id: id, ownerName: owner, ownerPID: pid, title: row[kCGWindowName as String] as? String,
                frame: frame, onScreen: (row[kCGWindowIsOnscreen as String] as? Bool) ?? false
            )
        }
    }

    func raise(windowWithFrame frame: WindowFrameRecord, pid: Int) -> Bool {
        let application = AXUIElementCreateApplication(pid_t(pid))
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return false }
        guard let match = windows.first(where: { Self.axFrame($0) == frame }) else { return false }
        return AXUIElementPerformAction(match, kAXRaiseAction as CFString) == .success
    }

    private static func frame(_ bounds: [String: Double]) -> WindowFrameRecord? {
        guard let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"] else { return nil }
        return WindowFrameRecord(x: x, y: y, width: width, height: height)
    }

    private static func axFrame(_ window: AXUIElement) -> WindowFrameRecord? {
        var point = CGPoint.zero
        var size = CGSize.zero
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return WindowFrameRecord(x: point.x, y: point.y, width: size.width, height: size.height)
    }
}
#endif
