#if os(macOS)
import Foundation
import PalBotProfile
import PalProtocol
import Testing

@testable import Pal

@MainActor
@Suite("Provider onboarding guards", .serialized)
struct ProviderOnboardingGuardTests {
    private let codexRow = providerRow("openai-codex", kind: "device_code", state: "set")
    private let keyRow = providerRow("openrouter", kind: "api_key")
    private let secret = SecretString("sk-fake-placeholder")

    private func codex(_ model: ProviderOnboardingModel) -> ModelProvider {
        model.providers.provider(id: "openai-codex") ?? plainProvider("openai-codex", .deviceCode)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<100_000 {
            if condition() { return }
            await Task.yield()
        }
    }

    @Test func theModelCannotChangeWhileSavingAndTheFieldDoesNotDrift() async {
        let backend = ScriptedBackend()
        let model = await makeOnboarding([keyRow], backend: backend)
        model.continueWithKey("openrouter", key: secret)
        model.setManualModel("first-model")
        await model.runTest()
        #expect(model.flow.canSaveAndContinue && model.modelsAreEditable)
        backend.holdPins()
        let saving = Task { await model.saveAndContinue() }
        await waitUntil { model.flow.isSaving }
        #expect(model.flow.isSaving && !model.modelsAreEditable)
        model.setManualModel("second-model")
        model.pick(model: "third-model")
        #expect(model.manualModel == "first-model" && model.selectedModel == "first-model" && model.flow.model == "first-model")
        backend.releasePins()
        await saving.value
    }

    @Test func aBlankModelNameClearsTheChoiceAndBlocksTheTest() async {
        let model = await makeOnboarding([codexRow])
        model.startTest(codex(model))
        model.setManualModel("some-model")
        #expect(model.flow.model == "some-model" && model.canTest)
        model.setManualModel("   ")
        #expect(model.selectedModel == nil && model.flow.model == nil && !model.canTest && !model.flow.canTest)
        model.setManualModel("other-model")
        #expect(model.flow.model == "other-model" && model.canTest)
    }

    @Test func continueNeedsAConnectedProviderThatCanBeTested() async {
        let none = await makeOnboarding([keyRow])
        #expect(none.continueTarget == nil)
        let unusable = await makeOnboarding([providerRow("mystery", kind: "something_new", state: "set")])
        #expect(unusable.providers.hasConnectedProvider && unusable.continueTarget == nil)
        let usable = await makeOnboarding([codexRow, keyRow])
        #expect(usable.continueTarget?.id == "openai-codex")
    }

    @Test func skippingGreetsOnlyAfterAFreshListAndAFinishedRemoval() async {
        var greeted: Bool?
        let stub = ProviderListStub([codexRow])
        let stale = await makeOnboarding([], stub: stub) { greeted = $0 }
        stub.failLists()
        await stale.skip()
        #expect(greeted == false)

        let fresh = await makeOnboarding([codexRow]) { greeted = $0 }
        await fresh.skip()
        #expect(greeted == true)

        let backend = ScriptedBackend()
        backend.failRemovals()
        let stuck = await makeOnboarding([codexRow], backend: backend) { greeted = $0 }
        stuck.begin(codex(stuck), credential: .written, owns: true)
        await stuck.skip()
        #expect(backend.removals == ["openai-codex"] && greeted == false)

        let removable = ScriptedBackend()
        let clean = await makeOnboarding([codexRow], backend: removable) { greeted = $0 }
        clean.begin(codex(clean), credential: .written, owns: true)
        await clean.skip()
        #expect(removable.removals == ["openai-codex"] && greeted == true)
    }

    @Test func backingOutOfATokenThisFlowWroteRemovesItUnlessItPassed() async {
        let backend = ScriptedBackend()
        let model = await makeOnboarding([codexRow], backend: backend)
        model.begin(codex(model), credential: .written, owns: true)
        await model.back()
        #expect(backend.removals == ["openai-codex"] && model.screen == .choice && model.flow.provider == nil)

        let proven = ScriptedBackend()
        let passed = await makeOnboarding([codexRow], backend: proven)
        passed.begin(codex(passed), credential: .written, owns: true)
        passed.pick(model: "gpt-5")
        await passed.runTest()
        #expect(passed.flow.canSaveAndContinue)
        await passed.back()
        #expect(proven.removals.isEmpty && passed.flow.provider?.id == "openai-codex")

        let existing = ScriptedBackend()
        let kept = await makeOnboarding([codexRow], backend: existing)
        kept.startTest(codex(kept))
        await kept.back()
        #expect(existing.removals.isEmpty && kept.flow.provider?.id == "openai-codex")
    }

    @Test func aNewProviderIsRefusedWhileAnUnprovenTokenIsHeld() async {
        let backend = ScriptedBackend()
        let model = await makeOnboarding([codexRow, keyRow], backend: backend)
        model.begin(codex(model), credential: .written, owns: true)
        model.continueWithKey("openrouter", key: secret)
        #expect(model.screen == .test("openai-codex") && model.flow.provider?.id == "openai-codex" && model.flow.ownsCredential)
        await model.back()
        #expect(backend.removals == ["openai-codex"])
        model.continueWithKey("openrouter", key: secret)
        #expect(model.screen == .test("openrouter"))
    }

    @Test func aFinishedSignInReadsTheProviderAfterARefresh() async throws {
        let stub = ProviderListStub([providerRow("openai-codex", kind: "device_code")])
        let model = await makeOnboarding([], stub: stub)
        let provider = try #require(model.providers.provider(id: "openai-codex"))
        model.push(.signIn("openai-codex"))
        await model.providers.signIn(provider)
        await model.providers.signInResolved(requestID: "r1", service: nil, outcome: .signedIn, reason: nil)
        stub.setRows([codexRow])
        await model.signInSettled()
        #expect(model.screen == .test("openai-codex"))
        #expect(model.flow.provider?.state == .set && model.flow.ownsCredential)
    }

    @Test func onlyTheOpenSignInScreenAnswersItsPromptInline() async {
        let model = await makeOnboarding([codexRow, keyRow])
        #expect(model.inlineSignInService == nil)
        model.push(.signIn("openai-codex"))
        #expect(model.inlineSignInService == "provider:openai-codex")
        model.replaceTop(with: .key("openrouter"))
        #expect(model.inlineSignInService == nil)
    }

    @Test func cancellingTheSignInScrubsTheClipboardDeclinesAndGoesBack() async {
        let model = await makeOnboarding([codexRow])
        model.push(.signIn("openai-codex"))
        model.clipboardMark = Int.min
        var declined: [String] = []
        await model.cancelSignIn("openai-codex") { declined.append($0) }
        #expect(declined == ["provider:openai-codex"] && model.clipboardMark == nil && model.screen == .choice)
    }

    @Test func theSlowNoticeNamesTheRealDelayAndTimeout() {
        let face = ProviderTestFace.make(state: .slow, provider: "P", model: "m", savesOnContinue: false)
        #expect(face.title.contains("\(ProviderTestFlow.defaultSlowAfterSeconds)"))
        #expect(face.detail?.contains("\(ProviderTestRequest.defaultTimeoutSeconds)") == true)
    }
}
#endif
