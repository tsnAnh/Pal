import Foundation
import HermesDevice
import HermesProtocol
import Synchronization
import Testing

private func requiredEvent(
    _ requestID: String = "r1",
    service: String = "github",
    bot: String = "atlas",
    bots: [String]? = nil,
    flow: String = "device_code",
    reason: String = "missing",
    code: String? = "WDJB-MJHT",
    uri: String? = "https://github.com/login/device"
) -> GatewayEvent {
    var payload: [String: JSONValue] = [
        "request_id": .string(requestID), "service": .string(service), "service_name": "GitHub", "bot": .string(bot),
        "bots": .array((bots ?? [bot]).map(JSONValue.string)), "reason": .string(reason), "flow": .string(flow), "expires_in": 900,
    ]
    if let code { payload["user_code"] = .string(code) }
    if let uri { payload["verification_uri"] = .string(uri) }
    return GatewayEvent(type: "auth.required", payload: .object(payload))
}

private func resolvedEvent(_ requestID: String, _ outcome: String) -> GatewayEvent {
    GatewayEvent(type: "auth.resolved", payload: ["request_id": .string(requestID), "outcome": .string(outcome)])
}

private final class Recorder: Sendable {
    private let calls = Mutex<[(method: String, params: JSONValue?)]>([])
    private let reply: Mutex<JSONValue>
    private let failing: Mutex<Bool>

    init(reply: JSONValue = ["recorded": true], failing: Bool = false) {
        self.reply = Mutex(reply)
        self.failing = Mutex(failing)
    }

    func handle(_ method: String, _ params: JSONValue?) throws -> JSONValue {
        calls.withLock { $0.append((method, params)) }
        if failing.withLock({ $0 }) { throw DeviceToolHostError.offline }
        return reply.withLock { $0 }
    }

    func methods() -> [String] { calls.withLock { $0.map(\.method) } }
    func params(_ method: String) -> [JSONValue?] { calls.withLock { $0.filter { $0.method == method }.map(\.params) } }
}

private final class Opened: Sendable {
    private let urls = Mutex<[URL]>([])
    func record(_ url: URL) { urls.withLock { $0.append(url) } }
    var all: [URL] { urls.withLock { $0 } }
}

@MainActor
private func makeCenter(_ recorder: Recorder, _ opened: Opened, delay: Duration = .milliseconds(1)) -> ServiceSignInCenter {
    ServiceSignInCenter(
        call: { method, params in try recorder.handle(method, params) },
        openBrowser: { opened.record($0) },
        dismissDelay: delay
    )
}

@MainActor
private func settle(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@Suite("Auth wire decoding")
struct ServiceSignInWireTests {
    @Test func decodesValidRequired() throws {
        let event = try #require(AuthRequiredEvent(event: requiredEvent(bots: ["atlas", "echo", "echo"])))
        #expect(event.requestID == "r1")
        #expect(event.service == "github")
        #expect(event.serviceName == "GitHub")
        #expect(event.bots == ["atlas", "echo"])
        #expect(event.flow == .deviceCode)
        #expect(event.reason == .missing)
        #expect(event.userCode == "WDJB-MJHT")
        #expect(event.expiresIn == 900)
    }

    @Test func unknownEnumsFallBack() throws {
        let event = try #require(AuthRequiredEvent(event: requiredEvent(flow: "passkey", reason: "stolen")))
        #expect(event.flow == .unknown)
        #expect(event.reason == .unknown)
        let resolved = try #require(AuthResolvedEvent(event: resolvedEvent("r1", "exploded")))
        #expect(resolved.outcome == .unknown)
    }

    @Test func missingRequiredFieldsAreIgnored() {
        #expect(AuthRequiredEvent(event: GatewayEvent(type: "auth.required", payload: ["service": "github"])) == nil)
        #expect(AuthRequiredEvent(event: GatewayEvent(type: "auth.required", payload: ["request_id": "r1"])) == nil)
        #expect(AuthRequiredEvent(event: GatewayEvent(type: "auth.required")) == nil)
        #expect(AuthResolvedEvent(event: GatewayEvent(type: "auth.resolved", payload: [:])) == nil)
        #expect(AuthRequiredEvent(event: resolvedEvent("r1", "failed")) == nil)
    }

    @Test func optionalFieldsDefault() throws {
        let event = try #require(AuthRequiredEvent(event: GatewayEvent(type: "auth.required", payload: ["request_id": "r1", "service": "github", "bot": "atlas"])))
        #expect(event.serviceName == "github")
        #expect(event.bots == ["atlas"])
        #expect(event.userCode == nil)
        #expect(event.flow == .unknown)
    }
}

@MainActor
@Suite("Service sign-in center")
struct ServiceSignInCenterTests {
    @Test func repeatEventKeepsOneDialogAndMergesBots() {
        let center = makeCenter(Recorder(), Opened())
        center.receive(requiredEvent("r1", bots: ["atlas"]))
        center.receive(requiredEvent("r1", bots: ["atlas", "echo"]))
        center.receive(requiredEvent("r2", bot: "echo", bots: ["echo", "nova"]))
        #expect(center.dialogs.count == 1)
        #expect(center.current?.bots == ["atlas", "echo", "nova"])
        #expect(center.current?.requestID == "r2")
        #expect(center.current?.otherBotCount == 2)
    }

    @Test func differentServicesQueue() async {
        let center = makeCenter(Recorder(), Opened())
        center.receive(requiredEvent("r1", service: "github"))
        center.receive(requiredEvent("r2", service: "notion"))
        #expect(center.dialogs.count == 2)
        #expect(center.current?.service == "github")
        await center.notNow()
        #expect(center.current?.service == "notion")
    }

    @Test func deviceCodeSignInOpensBrowserAndAcks() async throws {
        let recorder = Recorder()
        let opened = Opened()
        let center = makeCenter(recorder, opened)
        center.receive(requiredEvent())
        await center.signIn()
        #expect(opened.all == [URL(string: "https://github.com/login/device")!])
        #expect(recorder.methods() == ["auth.signin"])
        #expect(recorder.params("auth.signin").first??["request_id"]?.stringValue == "r1")
        #expect(center.current?.phase == .signingIn)
        center.receive(resolvedEvent("r1", "signed_in"))
        #expect(center.current?.phase == .signedIn)
        #expect(await settle { center.current == nil })
    }

    @Test func oauthOpensReturnedAuthorizationURL() async {
        let recorder = Recorder(reply: ["recorded": true, "authorization_url": "https://example.com/authorize?state=abc"])
        let opened = Opened()
        let center = makeCenter(recorder, opened)
        center.receive(requiredEvent(flow: "oauth", code: nil, uri: nil))
        await center.signIn()
        #expect(opened.all == [URL(string: "https://example.com/authorize?state=abc")!])
        #expect(center.current?.phase == .signingIn)
    }

    @Test func nonHTTPSNeverOpens() async {
        let opened = Opened()
        let device = makeCenter(Recorder(), opened)
        device.receive(requiredEvent(uri: "http://github.com/login/device"))
        await device.signIn()
        #expect(device.current?.phase == .failed("We couldn't open the sign-in page."))

        let oauth = makeCenter(Recorder(reply: ["recorded": true, "authorization_url": "javascript:alert(1)"]), opened)
        oauth.receive(requiredEvent(flow: "oauth", code: nil, uri: nil))
        await oauth.signIn()
        if case .failed = oauth.current?.phase {} else { Issue.record("expected failure") }

        let file = makeCenter(Recorder(reply: ["recorded": true, "authorization_url": "file:///etc/passwd"]), opened)
        file.receive(requiredEvent(flow: "oauth", code: nil, uri: nil))
        await file.signIn()
        #expect(opened.all.isEmpty)
    }

    @Test func manualFlowHasNoSignIn() async {
        let recorder = Recorder()
        let opened = Opened()
        let center = makeCenter(recorder, opened)
        center.receive(requiredEvent(flow: "manual", code: nil, uri: nil))
        #expect(center.current?.canSignIn == false)
        await center.signIn()
        #expect(recorder.methods().isEmpty)
        #expect(opened.all.isEmpty)
        await center.notNow()
        #expect(recorder.methods() == ["auth.decline"])
        #expect(center.current == nil)
    }

    @Test func notNowDeclinesOnce() async {
        let recorder = Recorder()
        let center = makeCenter(recorder, Opened())
        center.receive(requiredEvent())
        await center.notNow()
        await center.notNow()
        #expect(recorder.methods() == ["auth.decline"])
        #expect(recorder.params("auth.decline").first??["request_id"]?.stringValue == "r1")
        #expect(center.current == nil)
    }

    @Test func failedAndTimedOutShowPlainText() async {
        let center = makeCenter(Recorder(), Opened())
        center.receive(requiredEvent("r1"))
        center.receive(resolvedEvent("r1", "failed"))
        #expect(center.current?.phase == .failed("Sign-in didn't finish."))
        let recorder = Recorder()
        let other = makeCenter(recorder, Opened())
        other.receive(requiredEvent("r2"))
        other.receive(resolvedEvent("r2", "timed_out"))
        #expect(other.current?.phase == .failed("Sign-in took too long and was stopped."))
        await other.notNow()
        #expect(recorder.methods().isEmpty)
        #expect(other.current == nil)
    }

    @Test func unknownResolvedIsIgnored() {
        let center = makeCenter(Recorder(), Opened())
        center.receive(requiredEvent("r1"))
        center.receive(resolvedEvent("nope", "signed_in"))
        #expect(center.current?.phase == .prompting)
        center.receive(GatewayEvent(type: "auth.required", payload: ["service": "x"]))
        #expect(center.dialogs.count == 1)
    }

    @Test func signInRPCFailureShowsFailure() async {
        let center = makeCenter(Recorder(failing: true), Opened())
        center.receive(requiredEvent())
        await center.signIn()
        #expect(center.current?.phase == .failed("We couldn't start sign-in. Please try again later."))
    }

    @Test func declinedElsewhereClosesDialog() {
        let center = makeCenter(Recorder(), Opened())
        center.receive(requiredEvent("r1"))
        center.receive(resolvedEvent("r1", "declined"))
        #expect(center.current == nil)
    }
}
