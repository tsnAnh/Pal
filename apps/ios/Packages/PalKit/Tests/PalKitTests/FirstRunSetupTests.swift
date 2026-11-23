import Foundation
import PalBotProfile
import PalChat
import PalDevice
import PalProtocol
import Synchronization
import Testing

private func provider(_ id: String, kind: ModelProviderKind = .apiKey, state: ModelProviderState = .notSet) -> ModelProvider {
    ModelProvider(id: id, name: id.capitalized, kind: kind, state: state)
}

private func keyRequired(_ requestID: String, service: String) -> GatewayEvent {
    GatewayEvent(
        type: "auth.required",
        payload: .object([
            "request_id": .string(requestID), "service": .string(service), "service_name": .string(service), "bot": "atlas",
            "bots": ["atlas"], "reason": "missing", "flow": "api_key", "expires_in": 900,
        ])
    )
}

private final class Calls: Sendable {
    private let methods = Mutex<[String]>([])
    func record(_ method: String) { methods.withLock { $0.append(method) } }
    var all: [String] { methods.withLock { $0 } }
}

@MainActor
private func center(_ calls: Calls) -> ServiceSignInCenter {
    ServiceSignInCenter(
        call: { method, _ in
            calls.record(method)
            return ["outcome": "stored"]
        },
        openBrowser: { _ in }
    )
}

@Suite("First run providers")
struct FirstRunProvidersTests {
    @Test func theShortListKeepsItsOrderAndSkipsIdsTheEngineDoesNotReturn() {
        let browser: Set<String> = ["nous", "openai-codex"]
        let catalogue = ["nous", "gemini", "anthropic", "openai-codex", "mistral"].map {
            provider($0, kind: browser.contains($0) ? .deviceCode : .apiKey)
        }
        #expect(FirstRunProviders.choices(from: catalogue).map(\.id) == ["anthropic", "openai-codex", "gemini", "nous"])
    }

    @Test func aProviderThatCannotSignInHereIsLeftOut() {
        let catalogue = [provider("anthropic", kind: .unsupported, state: .unsupported), provider("openrouter")]
        #expect(FirstRunProviders.choices(from: catalogue).map(\.id) == ["openrouter"])
    }

    @Test func onlyASetProviderCountsAsConnected() {
        #expect(!FirstRunProviders.hasConnected([provider("anthropic"), provider("openrouter", state: .expired)]))
        #expect(FirstRunProviders.hasConnected([provider("anthropic"), provider("openrouter", state: .set)]))
        #expect(!FirstRunProviders.hasConnected([]))
    }
}

@Suite("Owner welcome")
struct OwnerWelcomeTests {
    @Test func theGreetingIsHiddenAndNamesTheOwner() {
        let intro = BotIntro.ownerWelcome(ownerName: "  Anh ")
        #expect(intro.hidden)
        #expect(intro.text.contains("Their name is Anh;"))
        #expect(!intro.text.contains("—"))
    }

    @Test func withoutANameItNeverInventsOne() {
        let intro = BotIntro.ownerWelcome(ownerName: "   ")
        #expect(!intro.text.contains("Their name is"))
        #expect(intro.text.contains("without one"))
    }
}

@MainActor
@Suite("Inline provider sign-in")
struct InlineSignInTests {
    @Test func anInlineDialogNeverReachesTheSheetButStaysAddressable() {
        let center = center(Calls())
        center.answerInline(["provider:anthropic"])
        center.receive(keyRequired("r1", service: "provider:anthropic"))
        #expect(center.current == nil)
        #expect(center.dialog(for: "provider:anthropic")?.requestID == "r1")
    }

    @Test func aKeyGoesToTheNamedDialogEvenWhenAnotherOneIsCurrent() async {
        let calls = Calls()
        let center = center(calls)
        center.answerInline(["provider:anthropic"])
        center.receive(keyRequired("r1", service: "provider:anthropic"))
        center.receive(keyRequired("r2", service: "provider:openrouter"))
        #expect(center.current?.service == "provider:openrouter")
        await center.submitCredential(SecretString("sk-test"), for: "provider:anthropic")
        #expect(calls.all == ["auth.submit_credential"])
        #expect(center.dialog(for: "provider:anthropic")?.phase == .keySet)
        #expect(center.dialog(for: "provider:openrouter")?.phase == .prompting)
    }

    @Test func cancellingOneInlineDialogLeavesTheOthers() async {
        let center = center(Calls())
        center.answerInline(["provider:anthropic"])
        center.receive(keyRequired("r1", service: "provider:anthropic"))
        center.receive(keyRequired("r2", service: "provider:openrouter"))
        await center.notNow(for: "provider:anthropic")
        #expect(center.dialog(for: "provider:anthropic") == nil)
        #expect(center.dialog(for: "provider:openrouter") != nil)
    }

    @Test func aNamedServiceWithoutADialogDoesNotFallBackToTheCurrentOne() async {
        let calls = Calls()
        let center = center(calls)
        center.receive(keyRequired("r2", service: "provider:openrouter"))
        await center.submitCredential(SecretString("sk-test"), for: "provider:anthropic")
        #expect(calls.all.isEmpty)
    }

    @Test func withNothingClaimedTheFirstDialogIsStillCurrent() {
        let center = center(Calls())
        center.receive(keyRequired("r1", service: "provider:anthropic"))
        #expect(center.current?.service == "provider:anthropic")
    }
}
