import Foundation
import PalDevice
import PalProtocol
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
    uri: String? = "https://github.com/login/device",
    server: String? = nil
) -> GatewayEvent {
    var payload: [String: JSONValue] = [
        "request_id": .string(requestID), "service": .string(service), "service_name": "GitHub", "bot": .string(bot),
        "bots": .array((bots ?? [bot]).map(JSONValue.string)), "reason": .string(reason), "flow": .string(flow), "expires_in": 900,
    ]
    if let code { payload["user_code"] = .string(code) }
    if let uri { payload["verification_uri"] = .string(uri) }
    if let server { payload["server"] = .string(server) }
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

private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

@MainActor
private func makeGatedCenter(_ recorder: Recorder, _ gate: Gate) -> ServiceSignInCenter {
    ServiceSignInCenter(
        call: { method, params in
            await gate.wait()
            return try recorder.handle(method, params)
        },
        openBrowser: { _ in },
        dismissDelay: .seconds(30)
    )
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

    @Test func oauthPasteFlowDecodes() throws {
        let event = try #require(AuthRequiredEvent(event: requiredEvent(flow: "oauth_paste", code: nil)))
        #expect(event.flow == .oauthPaste)
        #expect(event.userCode == nil)
        #expect(AuthCallbackResult(["outcome": "failed", "reason": "Try again."]) == AuthCallbackResult(outcome: .failed, reason: "Try again."))
        #expect(AuthCallbackResult(["outcome": "stored", "reason": ""]).reason == nil)
        #expect(AuthCallbackResult(["outcome": "weird"]).outcome == .unknown)
    }

    @Test func pastedCallbackNormalizes() {
        #expect(PastedCallback("  http://127.0.0.1:1/cb?code=a \n")?.value == "http://127.0.0.1:1/cb?code=a")
        #expect(PastedCallback("") == nil)
        #expect(PastedCallback(" \n\t ") == nil)
        #expect(PastedCallback(String(repeating: "a", count: 4096)) != nil)
        #expect(PastedCallback(String(repeating: "a", count: 4097)) == nil)
        #expect("\(PastedCallback("secret")!)" == "PastedCallback(redacted)")
    }

    @Test func unknownEnumsFallBack() throws {
        let event = try #require(AuthRequiredEvent(event: requiredEvent(flow: "passkey", reason: "stolen")))
        #expect(event.flow == .unknown)
        #expect(event.reason == .unknown)
        let resolved = try #require(AuthResolvedEvent(event: resolvedEvent("r1", "exploded")))
        #expect(resolved.outcome == .unknown)
    }

    @Test func decodesKeyAndHeaderFlowsWithServer() throws {
        let key = try #require(AuthRequiredEvent(event: requiredEvent(flow: "api_key", code: nil, uri: nil, server: "linear")))
        #expect(key.flow == .apiKey)
        #expect(key.server == "linear")
        let header = try #require(AuthRequiredEvent(event: requiredEvent(flow: "header", code: nil, uri: nil, server: "docs")))
        #expect(header.flow == .header)
        #expect(header.server == "docs")
        let none = try #require(AuthRequiredEvent(event: requiredEvent()))
        #expect(none.server == nil)
    }

    @Test func flowRawValuesDoNotDrift() {
        let known = ServiceSignInFlow.allCases.filter { $0 != .unknown }.map(\.rawValue)
        #expect(known == ["device_code", "oauth", "api_key", "header", "manual"])
        #expect(ServiceSignInFlow.allCases.count == known.count + 1)
        #expect(ServiceSignInFlow(wire: "passkey") == .unknown)
        #expect(ServiceSignInFlow(wire: nil) == .unknown)
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

    @Test func oauthPasteOpensBrowserOnceAndAcknowledges() async throws {
        let recorder = Recorder()
        let opened = Opened()
        let center = makeCenter(recorder, opened)
        center.receive(requiredEvent(flow: "oauth_paste", code: nil, uri: "https://auth.example.com/authorize?state=s"))
        #expect(center.current?.flow == .oauthPaste)
        #expect(center.current?.canSignIn == true)
        #expect(center.current?.takesKey == false)
        await center.signIn()
        await center.signIn()
        #expect(opened.all.map(\.absoluteString) == ["https://auth.example.com/authorize?state=s"])
        #expect(recorder.methods() == ["auth.signin"])
        #expect(center.current?.phase == .signingIn)
    }

    @Test func oauthPasteRejectsInsecureAuthorizationURL() async {
        let recorder = Recorder()
        let opened = Opened()
        let center = makeCenter(recorder, opened)
        center.receive(requiredEvent(flow: "oauth_paste", code: nil, uri: "http://auth.example.com/authorize"))
        await center.signIn()
        #expect(opened.all.isEmpty)
        #expect(recorder.methods().isEmpty)
        if case .failed = center.current?.phase {} else { Issue.record("expected failure") }
    }

    @Test func submitCallbackSendsPastedValueAndWaitsForResolution() async throws {
        let recorder = Recorder(reply: ["outcome": "stored"])
        let center = makeCenter(recorder, Opened(), delay: .seconds(30))
        center.receive(requiredEvent(flow: "oauth_paste", code: nil, uri: "https://auth.example.com/a"))
        await center.submitCallback("http://127.0.0.1:1455/cb?code=c&state=s")
        #expect(recorder.methods().isEmpty)
        await center.signIn()
        await center.submitCallback("  http://127.0.0.1:1455/cb?code=c&state=s \n")
        let params = try #require(recorder.params("auth.submit_callback").first ?? nil)
        #expect(params["request_id"]?.stringValue == "r1")
        #expect(params["value"]?.stringValue == "http://127.0.0.1:1455/cb?code=c&state=s")
        #expect(center.current?.phase == .signingIn)
        center.receive(resolvedEvent("r1", "signed_in"))
        #expect(center.current?.phase == .signedIn)
        await center.submitCallback("http://127.0.0.1:1455/cb?code=c&state=s")
        #expect(recorder.params("auth.submit_callback").count == 1)
    }

    @Test func submitCallbackFailureKeepsPasteOpenAndAllowsRetry() async {
        let recorder = Recorder(reply: ["outcome": "failed", "reason": "That address is for a different sign-in."])
        let center = makeCenter(recorder, Opened())
        center.receive(requiredEvent(flow: "oauth_paste", code: nil, uri: "https://auth.example.com/a"))
        await center.signIn()
        await center.submitCallback("http://127.0.0.1/cb?code=x")
        #expect(center.current?.phase == .callbackFailed("That address is for a different sign-in."))
        await center.submitCallback("http://127.0.0.1/cb?code=y&state=s")
        #expect(recorder.params("auth.submit_callback").count == 2)
        #expect(center.current?.phase == .callbackFailed("That address is for a different sign-in."))
        center.receive(resolvedEvent("r1", "failed"))
        if case .failed = center.current?.phase {} else { Issue.record("expected ended flow") }
    }

    @Test func submitCallbackRejectedExpiresAndTransportErrorKeepsPasteOpen() async {
        let rejected = makeCenter(Recorder(reply: ["outcome": "rejected"]), Opened())
        rejected.receive(requiredEvent(flow: "oauth_paste", code: nil, uri: "https://auth.example.com/a"))
        await rejected.signIn()
        await rejected.submitCallback("http://127.0.0.1/cb?code=x")
        #expect(rejected.current?.phase == .expired)

        let offline = ServiceSignInCenter(
            call: { method, _ in
                if method == "auth.submit_callback" { throw DeviceToolHostError.offline }
                return ["recorded": true]
            },
            openBrowser: { _ in },
            dismissDelay: .seconds(30)
        )
        offline.receive(requiredEvent(flow: "oauth_paste", code: nil, uri: "https://auth.example.com/a"))
        await offline.submitCallback("http://127.0.0.1/cb?code=x")
        #expect(offline.current?.phase == .prompting)
        await offline.signIn()
        await offline.submitCallback("http://127.0.0.1/cb?code=x")
        #expect(offline.current?.phase == .callbackFailed(ServiceSignInCenter.callbackFailure))
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

    @Test func submitStoresThroughOneCallAndKeepsTheValueOnlyInThatRequest() async {
        let secret = "CANARY-\(UUID().uuidString)"
        let recorder = Recorder(reply: ["outcome": "stored"])
        let center = makeCenter(recorder, Opened())
        center.receive(requiredEvent(flow: "api_key", code: nil, uri: nil, server: "linear"))
        #expect(center.current?.takesKey == true)
        await center.signIn()
        #expect(recorder.methods().isEmpty)
        await center.submitCredential(SecretString(secret))
        #expect(recorder.methods() == ["auth.submit_credential"])
        let sent = recorder.params("auth.submit_credential").first ?? nil
        #expect(sent?["request_id"]?.stringValue == "r1")
        #expect(sent?["value"]?.stringValue == secret)
        #expect(center.current?.phase == .keySet)
        #expect(!String(reflecting: center.dialogs).contains(secret))
        #expect(!"\(center.dialogs)".contains(secret))
        center.receive(resolvedEvent("r1", "signed_in"))
        #expect(center.current?.phase == .signedIn)
        #expect(await settle { center.current == nil })
    }

    @Test(arguments: [("failed", "retryable"), ("unknown", "retryable"), ("rejected", "expired")])
    func submitOutcomesMapToPhases(outcome: String, kind: String) async {
        let secret = "CANARY-\(UUID().uuidString)"
        let center = makeCenter(Recorder(reply: ["outcome": .string(outcome)]), Opened())
        center.receive(requiredEvent(flow: "api_key", code: nil, uri: nil, server: "linear"))
        await center.submitCredential(SecretString(secret))
        if kind == "expired" {
            #expect(center.current?.phase == .expired)
            #expect(center.current?.acceptsKey == false)
        } else {
            #expect(center.current?.phase == .keyFailed("Couldn't save that. Check it and try again."))
            #expect(center.current?.acceptsKey == true)
        }
        #expect(!String(reflecting: center.dialogs).contains(secret))
        var dumped = ""
        dump(center, to: &dumped)
        #expect(!dumped.contains(secret))
    }

    @Test func aThrownSubmitIsRetryableAndLeavesNoValue() async {
        let secret = "CANARY-\(UUID().uuidString)"
        let recorder = Recorder(failing: true)
        let center = makeCenter(recorder, Opened())
        center.receive(requiredEvent(flow: "api_key", code: nil, uri: nil, server: "linear"))
        await center.submitCredential(SecretString(secret))
        #expect(center.current?.phase == .keyFailed("Couldn't save that. Check it and try again."))
        #expect(center.current?.acceptsKey == true)
        #expect(!String(reflecting: center.dialogs).contains(secret))
        await center.submitCredential(SecretString(secret))
        #expect(recorder.methods() == ["auth.submit_credential", "auth.submit_credential"])
    }

    @Test func aSecondSubmitWhileOneIsInFlightIsIgnored() async {
        let recorder = Recorder(reply: ["outcome": "stored"])
        let gate = Gate()
        let center = makeGatedCenter(recorder, gate)
        center.receive(requiredEvent(flow: "api_key", code: nil, uri: nil, server: "linear"))
        let first = Task { await center.submitCredential(SecretString("first")) }
        #expect(await settle { center.current?.phase == .signingIn })
        await center.submitCredential(SecretString("second"))
        await gate.open()
        await first.value
        #expect(recorder.methods() == ["auth.submit_credential"])
        #expect(recorder.params("auth.submit_credential").first??["value"]?.stringValue == "first")
        #expect(center.current?.phase == .keySet)
    }

    @Test func aResolvedEventBeforeTheReplyWins() async {
        let recorder = Recorder(reply: ["outcome": "stored"])
        let gate = Gate()
        let center = makeGatedCenter(recorder, gate)
        center.receive(requiredEvent(flow: "api_key", code: nil, uri: nil, server: "linear"))
        let submit = Task { await center.submitCredential(SecretString("value")) }
        #expect(await settle { center.current?.phase == .signingIn })
        center.receive(resolvedEvent("r1", "signed_in"))
        await gate.open()
        await submit.value
        #expect(center.current?.phase == .signedIn)
    }

    @Test func submitIsIgnoredForEmptyValuesAndNonKeyFlows() async {
        let recorder = Recorder()
        let center = makeCenter(recorder, Opened())
        center.receive(requiredEvent(flow: "api_key", code: nil, uri: nil, server: "linear"))
        await center.submitCredential(SecretString(""))
        await center.notNow()
        for flow in ["oauth", "device_code", "manual"] {
            let other = makeCenter(recorder, Opened())
            other.receive(requiredEvent(flow: flow))
            #expect(other.current?.takesKey == false)
            await other.submitCredential(SecretString("abc"))
        }
        #expect(recorder.methods() == ["auth.decline"])
    }

    @Test func headerFlowTakesTheBoxAndOffersNoSignIn() async {
        let secret = "CANARY-\(UUID().uuidString)"
        let recorder = Recorder(reply: ["outcome": "stored"])
        let center = makeCenter(recorder, Opened())
        center.receive(requiredEvent(flow: "header", code: nil, uri: nil, server: "docs"))
        #expect(center.current?.canSignIn == false)
        #expect(center.current?.takesKey == true)
        await center.signIn()
        #expect(recorder.methods().isEmpty)
        await center.submitCredential(SecretString(secret))
        #expect(recorder.methods() == ["auth.submit_credential"])
        #expect(recorder.params("auth.submit_credential").first??["request_id"]?.stringValue == "r1")
        #expect(center.current?.phase == .keySet)
    }

    @Test func timedOutExpiresKeyDialogsAndFailsTheRest() async {
        let recorder = Recorder()
        for flow in ["api_key", "header"] {
            let center = makeCenter(recorder, Opened())
            center.receive(requiredEvent("r1", flow: flow, code: nil, uri: nil, server: "linear"))
            center.receive(resolvedEvent("r1", "timed_out"))
            #expect(center.current?.phase == .expired)
            #expect(center.current?.acceptsKey == false)
            await center.notNow()
            #expect(center.current == nil)
        }
        let oauth = makeCenter(recorder, Opened())
        oauth.receive(requiredEvent("r2", flow: "oauth", code: nil, uri: nil))
        oauth.receive(resolvedEvent("r2", "timed_out"))
        #expect(oauth.current?.phase == .failed("Sign-in took too long and was stopped."))
        #expect(recorder.methods().isEmpty)
    }

    @Test func cancellingDeclinesOnceAndRetainsNothing() async {
        let secret = "CANARY-\(UUID().uuidString)"
        let recorder = Recorder(reply: ["outcome": "failed"])
        let center = makeCenter(recorder, Opened())
        center.receive(requiredEvent(flow: "api_key", code: nil, uri: nil, server: "linear"))
        await center.submitCredential(SecretString(secret))
        await center.notNow()
        #expect(center.dialogs.isEmpty)
        #expect(recorder.methods() == ["auth.submit_credential", "auth.decline"])
        #expect(recorder.params("auth.decline").first??["value"] == nil)
        var dumped = ""
        dump(center, to: &dumped)
        #expect(!dumped.contains(secret))
    }
}

@Suite("Credential wire")
struct CredentialWireTests {
    @Test func methodAndParamsCarryTheValueOnlyInTheRequest() {
        let secret = "CANARY-\(UUID().uuidString)"
        #expect(ServiceSignInWire.submitCredentialMethod == "auth.submit_credential")
        let params = ServiceSignInWire.submitCredentialParams(requestID: "req-12345678", value: SecretString(secret))
        #expect(params["request_id"]?.stringValue == "req-12345678")
        #expect(params["value"]?.stringValue == secret)
        #expect(params.objectValue?.count == 2)
    }

    @Test(arguments: [("stored", AuthCredentialOutcome.stored), ("failed", AuthCredentialOutcome.failed), ("rejected", AuthCredentialOutcome.rejected), ("weird", AuthCredentialOutcome.unknown)])
    func outcomeParsing(wire: String, expected: AuthCredentialOutcome) {
        #expect(AuthCredentialOutcome(["outcome": .string(wire)]) == expected)
    }

    @Test func aMissingOutcomeIsUnknown() {
        #expect(AuthCredentialOutcome([:]) == .unknown)
        #expect(AuthCredentialOutcome(wire: nil) == .unknown)
    }
}
