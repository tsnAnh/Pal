#if os(macOS)
import AppKit
import Foundation

struct ScriptFailure: Error, Equatable {
    var number: Int
    var message: String
}

protocol ScriptRunning: Sendable {
    func run(_ source: String) async throws -> String
}

struct AppleEventRunner: ScriptRunning {
    func run(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(throwing: ScriptFailure(number: 0, message: "The script could not be built."))
                    return
                }
                var info: NSDictionary?
                let result = script.executeAndReturnError(&info)
                if let info {
                    continuation.resume(throwing: ScriptFailure(
                        number: (info["NSAppleScriptErrorNumber"] as? Int) ?? 0,
                        message: (info["NSAppleScriptErrorMessage"] as? String) ?? ""
                    ))
                } else {
                    continuation.resume(returning: result.stringValue ?? "")
                }
            }
        }
    }
}

private struct PageSnapshot: Decodable {
    var url: String
    var title: String
    var text: String
    var login: Bool
    var ready: String
    var matched: Bool?
    var error: String?
}

public actor SystemBrowser: BrowserProviding {
    private let runner: any ScriptRunning
    private let defaultTarget: @Sendable () -> BrowserTarget?
    private var target: BrowserTarget?
    private var windowID: Int?

    public init() {
        self.init(runner: AppleEventRunner(), defaultTarget: SystemBrowser.systemDefaultTarget)
    }

    init(runner: any ScriptRunning, defaultTarget: @escaping @Sendable () -> BrowserTarget?) {
        self.runner = runner
        self.defaultTarget = defaultTarget
    }

    static func systemDefaultTarget() -> BrowserTarget? {
        guard let probe = URL(string: "https://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: probe),
              let bundleID = Bundle(url: app)?.bundleIdentifier,
              let known = BrowserFamily.bundles[bundleID] else { return nil }
        return BrowserTarget(family: known.family, name: known.name, bundleID: bundleID)
    }

    public func open(url: URL, captureLimit: Int, timeout: Duration) async throws -> BrowserPageRecord {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw DeviceProviderError.invalidArgs("Only http and https pages can be opened.")
        }
        let browser = try resolveTarget()
        if let id = windowID, await windowStillOpen(browser, id) {
            _ = try await script(BrowserScripts.navigate(browser, windowID: id, url: url.absoluteString))
        } else {
            let answer = try await script(BrowserScripts.openWindow(browser, url: url.absoluteString))
            guard let id = Int(answer.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw DeviceProviderError.failed("The browser did not open a window.")
            }
            windowID = id
        }
        try await Task.sleep(for: .milliseconds(300))
        let page = try await settle(browser, timeout: timeout, captureLimit: captureLimit)
        if let final = URL(string: page.url), let finalScheme = final.scheme?.lowercased(), finalScheme != "http", finalScheme != "https" {
            try? await close()
            throw DeviceProviderError.failed("The page ended somewhere that is not a web page.")
        }
        return page
    }

    public func read(captureLimit: Int) async throws -> BrowserPageRecord {
        try await snapshot(BrowserScripts.read, captureLimit: captureLimit)
    }

    public func click(selector: String?, text: String?, captureLimit: Int) async throws -> BrowserPageRecord {
        try await snapshot(BrowserScripts.click(selector: selector, text: text), captureLimit: captureLimit)
    }

    public func type(selector: String, text: String, submit: Bool, captureLimit: Int) async throws -> BrowserPageRecord {
        try await snapshot(BrowserScripts.type(selector: selector, text: text, submit: submit), captureLimit: captureLimit)
    }

    public func waitForText(_ text: String, timeout: Duration, captureLimit: Int) async throws -> BrowserPageRecord {
        let deadline = ContinuousClock.now + timeout
        while true {
            let page = try await snapshot(BrowserScripts.contains(text), captureLimit: captureLimit)
            if page.matched == true || ContinuousClock.now >= deadline { return page }
            try await Task.sleep(for: BrowserScripts.pollInterval)
        }
    }

    public func close() async throws {
        guard let browser = target, let id = windowID else { return }
        windowID = nil
        if await windowStillOpen(browser, id) { _ = try await script(BrowserScripts.closeWindow(browser, windowID: id)) }
    }

    private func resolveTarget() throws -> BrowserTarget {
        guard let found = defaultTarget() else {
            throw DeviceProviderError.failed("Your default browser cannot be used by Hermes. Make Safari, Chrome, Brave, Edge, Arc or Vivaldi your default browser in System Settings, then try again.")
        }
        if let current = target, current != found { windowID = nil }
        target = found
        return found
    }

    private func windowStillOpen(_ browser: BrowserTarget, _ id: Int) async -> Bool {
        let answer = try? await runner.run(BrowserScripts.windowExists(browser, windowID: id))
        return answer?.lowercased() == "true"
    }

    private func settle(_ browser: BrowserTarget, timeout: Duration, captureLimit: Int) async throws -> BrowserPageRecord {
        let deadline = ContinuousClock.now + timeout
        while true {
            let (page, ready) = try await capture(BrowserScripts.read, captureLimit: captureLimit)
            if ready || ContinuousClock.now >= deadline { return page }
            try await Task.sleep(for: BrowserScripts.pollInterval)
        }
    }

    private func snapshot(_ source: String, captureLimit: Int) async throws -> BrowserPageRecord {
        try await capture(source, captureLimit: captureLimit).page
    }

    private func capture(_ source: String, captureLimit: Int) async throws -> (page: BrowserPageRecord, ready: Bool) {
        guard let browser = target, let id = windowID else {
            throw DeviceProviderError.invalidArgs("No page is open. Open one first.")
        }
        let answer = try await script(BrowserScripts.runInWindow(browser, windowID: id, script: source))
        guard let data = answer.data(using: .utf8), let snap = try? JSONDecoder().decode(PageSnapshot.self, from: data) else {
            throw DeviceProviderError.failed("The page did not answer.")
        }
        switch snap.error {
        case "not_found": throw DeviceProviderError.notFound
        case "password": throw DeviceProviderError.invalidArgs("That is a password field. The user types it on this Mac.")
        case "not_editable": throw DeviceProviderError.invalidArgs("That element cannot be typed into.")
        default: break
        }
        let bytes = Array(snap.text.utf8)
        let text = TextCap.capture(bytes, totalBytes: bytes.count, limit: captureLimit)
        let page = BrowserPageRecord(url: snap.url, title: snap.title, text: text, loginRequired: snap.login, matched: snap.matched)
        return (page, snap.ready == "complete")
    }

    private func script(_ source: String) async throws -> String {
        do {
            return try await runner.run(source)
        } catch let failure as ScriptFailure {
            throw map(failure)
        }
    }

    private func map(_ failure: ScriptFailure) -> DeviceProviderError {
        let message = failure.message.lowercased()
        if failure.number == -1743 { return .permissionDenied }
        if message.contains("apple events"), message.contains("javascript") {
            let hint = target?.family.setupHint ?? BrowserFamily.chromium.setupHint
            return .failed("Hermes may not run scripts in your browser yet. \(hint)")
        }
        if failure.number == -1728 || message.contains("can’t get window") || message.contains("can't get window") {
            windowID = nil
            return .failed("The browser window was closed. Open the page again.")
        }
        return .failed("The browser did not answer.")
    }
}
#endif
