import Foundation
import PalDevice
import PalProtocol
import Synchronization
import Testing

private let codexService = "provider:openai-codex"
private let otherService = "provider:nous"

private func deviceCodeRequired(_ requestID: String, service: String, flow: String = "device_code", appSignIn: Bool = false) -> GatewayEvent {
    var payload: [String: JSONValue] = [
        "request_id": .string(requestID), "service": .string(service), "service_name": .string(service), "bot": "atlas", "bots": ["atlas"],
        "reason": "missing", "flow": .string(flow), "expires_in": 900,
        "user_code": "WDJB-MJHT", "verification_uri": "https://auth.example.com/device",
    ]
    if appSignIn { payload["signin_on"] = "owner_app" }
    return GatewayEvent(type: "auth.required", payload: .object(payload))
}

private final class Seen: Sendable {
    private let log = Mutex<[String]>([])
    func record(_ entry: String) { log.withLock { $0.append(entry) } }
    var all: [String] { log.withLock { $0 } }
}

@MainActor
private func makeCenter(_ seen: Seen, paste: ServicePasteSignIn? = nil, native: ServiceNativeSignIn? = nil) -> ServiceSignInCenter {
    ServiceSignInCenter(
        call: { method, params in
            seen.record(method + ":" + (params?["request_id"]?.stringValue ?? ""))
            return ["recorded": true, "outcome": "stored"]
        },
        openBrowser: { seen.record("open:" + $0.absoluteString) },
        nativeSignIn: native,
        pasteSignIn: paste,
        dismissDelay: .seconds(30)
    )
}

private func pasteRoute(_ seen: Seen, outcome: ServicePasteOutcome = .signedIn) -> ServicePasteSignIn {
    ServicePasteSignIn(
        begin: { service in
            seen.record("begin:" + service)
            return nil
        },
        submit: { service, text in
            seen.record("submit:" + service + ":" + text)
            return outcome
        },
        cancel: { seen.record("cancel:" + $0) },
        reopen: { seen.record("reopen:" + $0) }
    )
}

@MainActor
@Suite("Sign-in for a named service")
struct ServiceSignInForServiceTests {
    @Test("a device-code sign-in runs for an inline-answered service while nothing is current")
    func signInForInlineService() async {
        let seen = Seen()
        let center = makeCenter(seen)
        center.answerInline([codexService])
        center.receive(deviceCodeRequired("r1", service: codexService))
        #expect(center.current == nil)
        await center.signIn()
        #expect(seen.all.isEmpty)
        await center.signIn(for: codexService)
        #expect(seen.all == ["open:https://auth.example.com/device", "auth.signin:r1"])
        #expect(center.dialog(for: codexService)?.phase == .signingIn)
    }

    @Test("the named service is signed in even when another dialog is current, and the other is left alone")
    func signInTargetsTheNamedDialog() async {
        let seen = Seen()
        let center = makeCenter(seen)
        center.answerInline([codexService])
        center.receive(deviceCodeRequired("r1", service: codexService))
        center.receive(deviceCodeRequired("r2", service: otherService))
        #expect(center.current?.service == otherService)
        await center.signIn(for: codexService)
        #expect(seen.all.contains("auth.signin:r1") && !seen.all.contains("auth.signin:r2"))
        #expect(center.dialog(for: codexService)?.phase == .signingIn)
        #expect(center.dialog(for: otherService)?.phase == .prompting)
        await center.signIn(for: "provider:nobody")
        #expect(seen.all.filter { $0.hasPrefix("auth.signin") } == ["auth.signin:r1"])
    }

    @Test("pasting works for a named service: begin, reopen, submit the address")
    func pasteForInlineService() async {
        let seen = Seen()
        let center = makeCenter(seen, paste: pasteRoute(seen))
        center.answerInline([codexService])
        center.receive(deviceCodeRequired("r1", service: codexService, appSignIn: true))
        await center.signIn(for: codexService)
        #expect(center.dialog(for: codexService)?.phase == .pasteAddress(nil))
        center.reopenSignInPage(for: codexService)
        await center.submitAddress("http://127.0.0.1:1455/cb?code=c", for: codexService)
        #expect(seen.all == ["begin:\(codexService)", "reopen:\(codexService)", "submit:\(codexService):http://127.0.0.1:1455/cb?code=c"])
        #expect(center.dialog(for: codexService)?.phase == .signedIn)
    }

    @Test("without a service the calls still act on the current dialog only")
    func unchangedWithoutAService() async {
        let seen = Seen()
        let center = makeCenter(seen, paste: pasteRoute(seen))
        center.receive(deviceCodeRequired("r1", service: codexService, appSignIn: true))
        center.reopenSignInPage()
        await center.submitAddress("http://127.0.0.1:1455/cb?code=c")
        #expect(seen.all.isEmpty)
        await center.signIn()
        #expect(center.current?.phase == .pasteAddress(nil))
        center.reopenSignInPage()
        await center.submitAddress("http://127.0.0.1:1455/cb?code=c")
        #expect(seen.all == ["begin:\(codexService)", "reopen:\(codexService)", "submit:\(codexService):http://127.0.0.1:1455/cb?code=c"])
    }

    @Test("a pasted callback reaches the named service")
    func callbackForInlineService() async {
        let seen = Seen()
        let center = makeCenter(seen)
        center.answerInline([codexService])
        center.receive(deviceCodeRequired("r1", service: codexService, flow: "oauth_paste"))
        center.receive(deviceCodeRequired("r2", service: otherService))
        await center.signIn(for: codexService)
        await center.submitCallback("http://127.0.0.1:1455/cb?code=c&state=s", for: codexService)
        #expect(seen.all.contains("auth.submit_callback:r1"))
        #expect(!seen.all.contains { $0.hasSuffix(":r2") })
    }

    @Test("paste instead acts on the named service after the automatic sign-in failed")
    func pasteInsteadForInlineService() async {
        let seen = Seen()
        let center = makeCenter(
            seen, paste: pasteRoute(seen),
            native: { service in
                seen.record("native:" + service)
                return .failed("That didn't work.")
            })
        center.answerInline([codexService])
        center.receive(deviceCodeRequired("r1", service: codexService, appSignIn: true))
        await center.signIn(for: codexService)
        #expect(center.dialog(for: codexService)?.phase == .failed("That didn't work."))
        await center.signInByPasting()
        #expect(center.dialog(for: codexService)?.phase == .failed("That didn't work."))
        await center.signInByPasting(for: codexService)
        #expect(center.dialog(for: codexService)?.phase == .pasteAddress(nil))
        #expect(seen.all == ["native:\(codexService)", "begin:\(codexService)"])
    }
}
