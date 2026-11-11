import Foundation
@testable import HermesDevice
import HermesProtocol
import Synchronization
import Testing

private final class FakeBrowser: BrowserProviding {
    struct Recorded {
        var calls: [String] = []
        var timeouts: [Duration] = []
    }

    private let recorded = Mutex(Recorded())
    let page: BrowserPageRecord
    let failure: DeviceProviderError?

    init(page: BrowserPageRecord = BrowserPageRecord(url: "https://example.com/docs", title: "Docs", text: CapturedText(text: "Welcome back, Sam.")), failure: DeviceProviderError? = nil) {
        self.page = page
        self.failure = failure
    }

    var calls: [String] { recorded.withLock { $0.calls } }
    var timeouts: [Duration] { recorded.withLock { $0.timeouts } }

    private func record(_ call: String) throws -> BrowserPageRecord {
        recorded.withLock { $0.calls.append(call) }
        if let failure { throw failure }
        return page
    }

    func open(url: URL, captureLimit: Int, timeout: Duration) async throws -> BrowserPageRecord { try record("open \(url.absoluteString)") }
    func read(captureLimit: Int) async throws -> BrowserPageRecord { try record("read") }
    func click(selector: String?, text: String?, captureLimit: Int) async throws -> BrowserPageRecord { try record("click \(selector ?? "") \(text ?? "")") }
    func type(selector: String, text: String, submit: Bool, captureLimit: Int) async throws -> BrowserPageRecord { try record("type \(selector) \(submit)") }

    func waitForText(_ text: String, timeout: Duration, captureLimit: Int) async throws -> BrowserPageRecord {
        recorded.withLock { $0.timeouts.append(timeout) }
        return try record("wait \(text)")
    }

    func close() async throws { _ = try record("close") }
}

private func browserExecutor(
    _ state: DeviceConnectorState = .allowed, browser: FakeBrowser? = FakeBrowser()
) async -> DeviceToolExecutor {
    let ledger = ConnectorLedger(api: FakeConnectorsAPI([.browser: state]))
    _ = try? await ledger.refresh()
    return DeviceToolExecutor(
        providers: DeviceProviders(browser: browser), permissions: FakePermissions(), ledger: ledger, consent: FakeConsent(true),
        environment: DeviceToolEnvironment(deadlineMargin: .zero)
    )
}

private func browserCall(_ action: String, args: JSONValue = [:], deadline: Int = 30) -> DeviceToolRequest {
    DeviceToolRequest(
        requestID: "req-00000002", action: action, connector: DeviceToolAction(rawValue: action)?.connector.rawValue ?? "",
        args: args, needsConsent: false, profile: "default", deadlineSeconds: deadline
    )
}

private func failure(_ outcome: DeviceToolOutcome) -> (DeviceToolErrorCode, String)? {
    if case .failure(let code, let message) = outcome { return (code, message) }
    return nil
}

private func success(_ outcome: DeviceToolOutcome) -> JSONValue? {
    if case .success(let value) = outcome { return value }
    return nil
}

@Suite("Browser connector over the executor")
struct BrowserExecutorTests {
    @Test func openReturnsThePageWithItsTitleAndText() async throws {
        let browser = FakeBrowser()
        let executor = await browserExecutor(browser: browser)
        let value = try #require(success(await executor.execute(browserCall("browser.open", args: ["url": "https://example.com/docs"]))))
        #expect(browser.calls == ["open https://example.com/docs"])
        #expect(value["url"]?.stringValue == "https://example.com/docs")
        #expect(value["title"]?.stringValue == "Docs")
        #expect(value["text"]?.stringValue == "Welcome back, Sam.")
        #expect(value["login_required"]?.boolValue == false)
    }

    @Test func aLoginPageIsFlaggedSoTheGatewayCanRaiseTheSignInDialog() async throws {
        let page = BrowserPageRecord(url: "https://accounts.example.com/login", title: "Sign in", text: CapturedText(text: "Password"), loginRequired: true)
        let executor = await browserExecutor(browser: FakeBrowser(page: page))
        let value = try #require(success(await executor.execute(browserCall("browser.read"))))
        #expect(value["login_required"]?.boolValue == true)
    }

    @Test(arguments: ["file:///etc/passwd", "chrome://settings", "about:blank", "javascript:alert(1)", "ftp://example.com/a", "http://", "not a url"])
    func onlyWebAddressesOpen(url: String) async {
        let browser = FakeBrowser()
        let executor = await browserExecutor(browser: browser)
        let outcome = await executor.execute(browserCall("browser.open", args: ["url": .string(url)]))
        #expect(failure(outcome)?.0 == .invalidArgs)
        #expect(browser.calls.isEmpty)
    }

    @Test(arguments: ["input[type=password]", "#Password", "input[name=passcode]", "#one-time-code", "#otp"])
    func aPasswordFieldIsRefusedWithoutEchoingTheText(selector: String) async {
        let browser = FakeBrowser()
        let executor = await browserExecutor(browser: browser)
        let outcome = await executor.execute(browserCall("browser.type", args: ["selector": .string(selector), "text": "canary-pw-7d41e0"]))
        let refusal = failure(outcome)
        #expect(refusal?.0 == .invalidArgs)
        #expect(refusal?.1.contains("canary-pw-7d41e0") == false)
        #expect(browser.calls.isEmpty)
    }

    @Test func anOrdinaryFieldIsTypedInto() async {
        let browser = FakeBrowser()
        let executor = await browserExecutor(browser: browser)
        _ = await executor.execute(browserCall("browser.type", args: ["selector": "#footprint", "text": "hi", "submit": true]))
        #expect(browser.calls == ["type #footprint true"])
    }

    @Test func clickNeedsExactlyOneTarget() async {
        let browser = FakeBrowser()
        let executor = await browserExecutor(browser: browser)
        #expect(failure(await executor.execute(browserCall("browser.click")))?.0 == .invalidArgs)
        #expect(failure(await executor.execute(browserCall("browser.click", args: ["selector": "a", "text": "b"])))?.0 == .invalidArgs)
        #expect(browser.calls.isEmpty)
        _ = await executor.execute(browserCall("browser.click", args: ["text": "Next"]))
        #expect(browser.calls == ["click  Next"])
    }

    @Test(arguments: [(JSONValue.int(999), Duration.seconds(28)), (.int(0), .seconds(1)), (.null, .seconds(15))])
    func theWaitIsClampedToTheRequestBudget(seconds: JSONValue, expected: Duration) async {
        let browser = FakeBrowser()
        let executor = await browserExecutor(browser: browser)
        _ = await executor.execute(browserCall("browser.wait_for_text", args: ["text": "Results", "timeout_seconds": seconds], deadline: 30))
        #expect(browser.timeouts == [expected])
    }

    @Test func aPageOverTheCapEndsWithTheMarker() async throws {
        let big = CapturedText(text: String(repeating: "word ", count: 60_000))
        let executor = await browserExecutor(browser: FakeBrowser(page: BrowserPageRecord(url: "https://example.com", title: "t", text: big)))
        let value = try #require(success(await executor.execute(browserCall("browser.read"))))
        let text = try #require(value["text"]?.stringValue)
        #expect(value["truncated"]?.boolValue == true)
        #expect(text.hasSuffix("bytes omitted]"))
        #expect(text.utf8.count <= DeviceTextLimit.fileContent + 64)
    }

    @Test func theBrowserIsOffUntilTheUserTurnsItOn() async {
        let browser = FakeBrowser()
        let executor = await browserExecutor(.off, browser: browser)
        #expect(failure(await executor.execute(browserCall("browser.read")))?.0 == .consentDeclined)
        #expect(browser.calls.isEmpty)
    }

    @Test func aDeviceWithoutABrowserProviderIsUnsupported() async {
        let executor = await browserExecutor(browser: nil)
        #expect(failure(await executor.execute(browserCall("browser.read")))?.0 == .unsupported)
    }

    @Test func theConnectorIsNamedAndWarnsWhenTurnedOn() {
        #expect(DeviceConnectorDefaults.entry(for: .browser) == ("Browser", "Let bots use your browser on this Mac"))
        let warning = DeviceConnectorDefaults.warning(for: .browser)
        #expect(warning?.contains("drive a browser on this Mac") == true)
        #expect(warning?.contains("never sees your passwords") == true)
        let actions: [DeviceToolAction] = [.browserOpen, .browserRead, .browserClick, .browserType, .browserWaitForText, .browserClose]
        #expect(actions.allSatisfy { $0.connector == .browser })
        #expect(!DeviceConnectorID.browser.needsOSPermission)
    }
}

#if os(macOS)
private final class ScriptedRunner: ScriptRunning {
    private let log = Mutex<[String]>([])
    private let answer: @Sendable (String) throws -> String

    init(_ answer: @escaping @Sendable (String) throws -> String) { self.answer = answer }

    var sources: [String] { log.withLock { $0 } }

    func run(_ source: String) async throws -> String {
        log.withLock { $0.append(source) }
        return try answer(source)
    }
}

private let snapshotJSON = #"{"url":"https://example.com/docs","title":"Docs","text":"Welcome back, Sam.","login":false,"ready":"complete"}"#
private let chrome = BrowserTarget(family: .chromium, name: "Google Chrome", bundleID: "com.google.Chrome")
private let safari = BrowserTarget(family: .safari, name: "Safari", bundleID: "com.apple.Safari")

private func healthyBrowser(_ answers: @escaping @Sendable (String) throws -> String = { source in
    if source.contains("exists window id") { return "true" }
    if source.contains("make new") { return "42" }
    return snapshotJSON
}, target: BrowserTarget? = chrome) -> (SystemBrowser, ScriptedRunner) {
    let runner = ScriptedRunner(answers)
    return (SystemBrowser(runner: runner, defaultTarget: { target }), runner)
}

@Suite("Mac browser provider", .serialized)
struct SystemBrowserTests {
    @Test func openMakesOneWindowAndEveryLaterScriptTargetsOnlyThatWindow() async throws {
        let (browser, runner) = healthyBrowser()
        let page = try await browser.open(url: URL(string: "https://example.com/docs")!, captureLimit: 1000, timeout: .seconds(2))
        _ = try await browser.read(captureLimit: 1000)
        _ = try await browser.click(selector: "#next", text: nil, captureLimit: 1000)
        #expect(page.title == "Docs" && page.text.text == "Welcome back, Sam.")
        let sources = runner.sources
        #expect(sources.first?.contains("make new window") == true)
        #expect(sources.dropFirst().filter { $0.contains("javascript") }.allSatisfy { $0.contains("window id 42") })
        #expect(sources.allSatisfy { $0.contains("com.google.Chrome") })
    }

    @Test func safariOpensADocumentAndRunsJavaScriptInItsCurrentTab() async throws {
        let (browser, runner) = healthyBrowser(target: safari)
        _ = try await browser.open(url: URL(string: "https://example.com")!, captureLimit: 1000, timeout: .seconds(2))
        #expect(runner.sources.first?.contains("make new document") == true)
        #expect(runner.sources.contains { $0.contains("do JavaScript") && $0.contains("current tab of window id 42") })
    }

    @Test func aSecondOpenReusesTheWindowItMade() async throws {
        let (browser, runner) = healthyBrowser()
        _ = try await browser.open(url: URL(string: "https://example.com/a")!, captureLimit: 1000, timeout: .seconds(2))
        _ = try await browser.open(url: URL(string: "https://example.com/b")!, captureLimit: 1000, timeout: .seconds(2))
        #expect(runner.sources.filter { $0.contains("make new window") }.count == 1)
        #expect(runner.sources.contains { $0.contains("set URL of active tab of window id 42") && $0.contains("example.com/b") })
    }

    @Test func closeClosesOnlyItsWindowAndForgetsIt() async throws {
        let (browser, runner) = healthyBrowser()
        _ = try await browser.open(url: URL(string: "https://example.com")!, captureLimit: 1000, timeout: .seconds(2))
        try await browser.close()
        #expect(runner.sources.last == "tell application id \"com.google.Chrome\" to close window id 42")
        await #expect(throws: DeviceProviderError.invalidArgs("No page is open. Open one first.")) {
            _ = try await browser.read(captureLimit: 1000)
        }
    }

    @Test func nothingRunsBeforeAPageIsOpened() async {
        let (browser, runner) = healthyBrowser()
        await #expect(throws: DeviceProviderError.self) { _ = try await browser.click(selector: "a", text: nil, captureLimit: 100) }
        #expect(runner.sources.isEmpty)
    }

    @Test(arguments: ["file:///etc/hosts", "chrome://settings", "javascript:alert(1)"])
    func onlyWebSchemesAreOpened(url: String) async {
        let (browser, runner) = healthyBrowser()
        await #expect(throws: DeviceProviderError.self) { _ = try await browser.open(url: URL(string: url)!, captureLimit: 100, timeout: .seconds(1)) }
        #expect(runner.sources.isEmpty)
    }

    @Test func aLoginPageIsReportedNotFilledIn() async throws {
        let login = #"{"url":"https://accounts.example.com/login","title":"Sign in","text":"Password","login":true,"ready":"complete"}"#
        let (browser, runner) = healthyBrowser({ source in
            if source.contains("make new") { return "42" }
            return login
        })
        let page = try await browser.open(url: URL(string: "https://accounts.example.com/login")!, captureLimit: 1000, timeout: .seconds(2))
        #expect(page.loginRequired)
        #expect(runner.sources.allSatisfy { !$0.contains("el.focus()") })
    }

    @Test func aPageThatSaysPasswordFieldIsRefused() async throws {
        let (browser, _) = healthyBrowser({ source in
            if source.contains("exists window id") { return "true" }
            if source.contains("make new") { return "42" }
            if source.contains("el.focus()") { return #"{"error":"password","url":"u","title":"t","text":"","login":false,"ready":"complete"}"# }
            return snapshotJSON
        })
        _ = try await browser.open(url: URL(string: "https://example.com")!, captureLimit: 1000, timeout: .seconds(2))
        await #expect(throws: DeviceProviderError.invalidArgs("That is a password field. The user types it on this Mac.")) {
            _ = try await browser.type(selector: "#field", text: "x", submit: false, captureLimit: 100)
        }
    }

    @Test func theTypeScriptRefusesPasswordLikeFieldsInThePageItself() {
        let script = BrowserScripts.type(selector: "#a", text: "x", submit: false)
        #expect(script.contains("kind==='password'"))
        #expect(script.contains("error:'password'"))
    }

    @Test func macOSAutomationRefusalIsAPermissionFailure() async {
        let (browser, _) = healthyBrowser({ _ in throw ScriptFailure(number: -1743, message: "Not authorized to send Apple events") })
        await #expect(throws: DeviceProviderError.permissionDenied) {
            _ = try await browser.open(url: URL(string: "https://example.com")!, captureLimit: 100, timeout: .seconds(1))
        }
    }

    @Test func aBrowserWithJavaScriptFromAppleEventsOffGetsAPlainSetupHint() async {
        let (browser, _) = healthyBrowser({ source in
            if source.contains("make new") { return "42" }
            if source.contains("exists window id") { return "true" }
            throw ScriptFailure(number: 12, message: "Executing JavaScript through AppleScript is turned off. Allow JavaScript from Apple Events.")
        })
        do {
            _ = try await browser.open(url: URL(string: "https://example.com")!, captureLimit: 100, timeout: .seconds(1))
            Issue.record("expected a failure")
        } catch DeviceProviderError.failed(let message) {
            #expect(message.contains("Allow JavaScript from Apple Events"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func anUnsupportedDefaultBrowserFailsWithoutRunningAnything() async {
        let (browser, runner) = healthyBrowser(target: nil)
        await #expect(throws: DeviceProviderError.self) {
            _ = try await browser.open(url: URL(string: "https://example.com")!, captureLimit: 100, timeout: .seconds(1))
        }
        #expect(runner.sources.isEmpty)
    }

    @Test func textIsEscapedSoAPageValueCannotBreakOutOfTheScript() {
        let hostile = "\"; do shell script \"id\" --\\"
        let quoted = BrowserScripts.quoted(hostile)
        #expect(quoted == "\"\\\"; do shell script \\\"id\\\" --\\\\\"")
        let js = BrowserScripts.jsString("a\"b</script>\u{2028}")
        #expect(js.hasPrefix("\"") && js.hasSuffix("\"") && js.contains("\\\""))
        let source = BrowserScripts.runInWindow(chrome, windowID: 7, script: BrowserScripts.click(selector: hostile, text: nil))
        #expect(!source.contains("do shell script \"id\""))
    }

    @Test func theKnownBrowsersMapToTheirFamily() {
        #expect(BrowserFamily.bundles["com.apple.Safari"]?.family == .safari)
        #expect(BrowserFamily.bundles["com.google.Chrome"]?.family == .chromium)
        #expect(BrowserFamily.bundles["org.mozilla.firefox"] == nil)
    }
}
#endif
