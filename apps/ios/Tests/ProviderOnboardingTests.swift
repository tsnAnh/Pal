#if os(macOS)
import Foundation
import PalBotProfile
import PalProtocol
import Testing

@testable import Pal

@MainActor
@Suite("Provider onboarding", .serialized)
struct ProviderOnboardingTests {
    @Test func everyProviderKindOpensItsOwnPopup() {
        #expect(ProviderOnboardingModel.screen(for: plainProvider("openai-codex", .deviceCode)) == .signIn("openai-codex"))
        #expect(ProviderOnboardingModel.screen(for: plainProvider("minimax", .oauthPaste)) == .signIn("minimax"))
        #expect(ProviderOnboardingModel.screen(for: plainProvider("claude", .cliPlan)) == .claude("claude"))
        #expect(ProviderOnboardingModel.screen(for: plainProvider("openrouter", .apiKey)) == .key("openrouter"))
        #expect(ProviderOnboardingModel.screen(for: plainProvider(FirstRunProviders.localProviderID, .apiKey)) == .local)
    }

    @Test func providersThatCannotBeSetUpHereOpenNothing() {
        #expect(ProviderOnboardingModel.screen(for: plainProvider("other", .unsupported)) == nil)
        #expect(ProviderOnboardingModel.screen(for: plainProvider("other", .unknown)) == nil)
    }

    @Test func aKeyProviderOpensTheKeyPopupAndBackReturnsToTheChoice() async {
        let model = await makeOnboarding([providerRow("openrouter", kind: "api_key")])
        await model.choose(model.providers.provider(id: "openrouter") ?? plainProvider("openrouter", .apiKey))
        #expect(model.screen == .key("openrouter"))
        #expect(model.canGoBack)
        await model.back()
        #expect(model.screen == .choice)
        #expect(!model.canGoBack)
    }

    @Test func aConnectedProviderGoesStraightToTheTestWithoutOwningTheCredential() async {
        let model = await makeOnboarding([providerRow("openai-codex", kind: "device_code", state: "set")])
        let provider = model.providers.provider(id: "openai-codex") ?? plainProvider("openai-codex", .deviceCode)
        await model.choose(provider)
        #expect(model.screen == .test("openai-codex"))
        #expect(model.flow.state == .awaitingTest)
        #expect(!model.flow.ownsCredential)
        #expect(model.origin == .written)
    }

    @Test func aStagedKeyIsDroppedWhenTheOwnerBacksOutOfTheTest() async {
        let model = await makeOnboarding([providerRow("openrouter", kind: "api_key")])
        model.push(.key("openrouter"))
        model.continueWithKey("openrouter", key: SecretString("sk-fake-placeholder"))
        #expect(model.screen == .test("openrouter"))
        #expect(model.flow.hasStagedSecret)
        await model.back()
        #expect(model.screen == .key("openrouter"))
        #expect(!model.flow.hasStagedSecret)
        #expect(model.flow.state == .idle)
    }

    @Test func backingOutOfAWrittenTestKeepsTheProviderConnected() async {
        let model = await makeOnboarding([providerRow("openai-codex", kind: "device_code", state: "set")])
        model.startTest(model.providers.provider(id: "openai-codex") ?? plainProvider("openai-codex", .deviceCode))
        await model.back()
        #expect(model.screen == .choice)
        #expect(model.flow.provider?.id == "openai-codex")
    }

    @Test func pickingAModelEnablesTheTest() async {
        let model = await makeOnboarding([providerRow("openai-codex", kind: "device_code", state: "set")])
        model.startTest(model.providers.provider(id: "openai-codex") ?? plainProvider("openai-codex", .deviceCode))
        model.pick(model: "gpt-5")
        #expect(model.selectedModel == "gpt-5")
        #expect(model.canTest)
    }

    @Test func skippingFinishesWithoutAGreetingWhenNothingIsConnected() async {
        var greeted: Bool?
        let model = await makeOnboarding([providerRow("openrouter", kind: "api_key")]) { greeted = $0 }
        await model.skip()
        #expect(greeted == false)
    }

    @Test func theLocalAddressNeedsAWebSchemeAndAHost() {
        #expect(LocalAddress.normalized("http://localhost:11434/v1") == "http://localhost:11434/v1")
        #expect(LocalAddress.normalized("  https://models.example.com/v1  ") == "https://models.example.com/v1")
        #expect(LocalAddress.normalized("") == nil)
        #expect(LocalAddress.normalized("localhost:11434") == nil)
        #expect(LocalAddress.normalized("ftp://example.com") == nil)
        #expect(LocalAddress.normalized("http://") == nil)
    }

    @Test func aLongModelListShowsAFewRowsAndKeepsTheSelectedOne() {
        let names = (1...12).map { "model-\($0)" }
        let collapsed = ProviderOnboardingModel.collapse(names, selected: "model-9", showsAll: false)
        #expect(collapsed.count == ProviderOnboardingModel.collapsedModelCount + 1)
        #expect(collapsed.contains("model-9"))
        #expect(ProviderOnboardingModel.collapse(names, selected: nil, showsAll: true) == names)
        #expect(ProviderOnboardingModel.collapse(Array(names.prefix(3)), selected: nil, showsAll: false).count == 3)
    }
}

@Suite("Provider test footer")
struct ProviderTestFooterTests {
    private typealias Plan = ProviderTestFooterPlan

    @Test func aPassOffersSaveAndNeverTestsAgainAsThePrimary() {
        let plan = Plan.make(state: .passed(ProviderTestPass(model: "gpt-5", latencyMilliseconds: 1400)), options: .init())
        #expect(plan.primary == .saveAndContinue)
        #expect(plan.secondary == [.testAgain])
        #expect(plan.quiet == .skip)
    }

    @Test func aRunningTestOffersOnlyCancelAndABusyPrimary() {
        for state in [ProviderTestState.testing, .slow] {
            let plan = Plan.make(state: state, options: .init())
            #expect(plan.primary == .testing)
            #expect(plan.secondary == [.cancel])
            #expect(plan.quiet == nil)
        }
    }

    @Test func anAuthFailureOnATokenWrittenHereOffersSignInAgainAndRemove() {
        let options = Plan.Options(canSignInAgain: true, canRemove: true)
        let plan = Plan.make(state: .failed(reason: "Rejected.", kind: .auth), options: options)
        #expect(plan.secondary == [.signInAgain, .remove])
        #expect(plan.primary == .retry)
    }

    @Test func anAuthFailureOnAStagedKeyOffersChangeKeyAndNeverRemove() {
        let plan = Plan.make(state: .failed(reason: "Rejected.", kind: .auth), options: Plan.Options(isStaged: true, canSignInAgain: false))
        #expect(plan.secondary == [.changeKey])
    }

    @Test func aModelFailureOffersChangeModelOnlyWhenItIsAllowed() {
        let allowed = Plan.make(state: .failed(reason: "No such model.", kind: .model), options: Plan.Options(canChangeModel: true))
        #expect(allowed.secondary == [.changeModel])
        let refused = Plan.make(state: .failed(reason: "No such model.", kind: .model), options: .init())
        #expect(refused.secondary.isEmpty)
    }

    @Test func offlineAndUntestedStatesNeverOfferSave() {
        #expect(Plan.make(state: .offline, options: .init()).primary == .retry)
        for state in [ProviderTestState.idle, .awaitingTest, .modelChanged, .signingIn] {
            #expect(Plan.make(state: state, options: .init()).primary == .test)
        }
    }
}

@Suite("Provider test card")
struct ProviderTestFaceTests {
    private let english = Locale(identifier: "en_US")

    @Test func latencyReadsInSecondsWithOneDecimal() {
        #expect(ProviderTestFace.seconds(1400, locale: english).contains("1.4"))
        #expect(ProviderTestFace.seconds(0, locale: english).contains("0.0"))
        #expect(ProviderTestFace.seconds(-5, locale: english).contains("0.0"))
    }

    @Test func aPassSaysWorksAndNamesTheModel() {
        let pass = ProviderTestPass(model: "gpt-5", latencyMilliseconds: 1400)
        let face = ProviderTestFace.make(state: .passed(pass), provider: "OpenAI", model: "gpt-5", savesOnContinue: true, locale: english)
        #expect(face.slug == "passed")
        #expect(face.tone == .success)
        #expect(face.detail?.contains("gpt-5") == true)
        #expect(face.detail?.contains("Nothing is saved until you continue") == true)
    }

    @Test func aFailureShowsTheGatewayReasonUntouched() {
        let face = ProviderTestFace.make(
            state: .failed(reason: "The key was rejected.", kind: .auth), provider: "OpenAI", model: "gpt-5", savesOnContinue: false)
        #expect(face.slug == "failed")
        #expect(face.detail == "The key was rejected.")
        #expect(face.tone == .failure)
    }

    @Test func offlineNamesTheProviderAndEveryStateHasItsOwnSlug() {
        let offline = ProviderTestFace.make(state: .offline, provider: "OpenAI", model: "gpt-5", savesOnContinue: false)
        #expect(offline.detail?.contains("OpenAI") == true)
        let slugs = [ProviderTestState.idle, .awaitingTest, .testing, .slow, .offline, .modelChanged]
            .map { ProviderTestFace.make(state: $0, provider: "P", model: "m", savesOnContinue: false).slug }
        #expect(Set(slugs) == ["notTested", "testing", "slow", "offline", "modelChanged"])
    }
}
#endif
