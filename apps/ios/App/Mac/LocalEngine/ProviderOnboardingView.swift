#if os(macOS)
import PalBotProfile
import PalDesign
import PalDevice
import SwiftUI

struct ProviderOnboardingView: View {
    let model: ProviderOnboardingModel

    @Environment(ServiceSignInCenter.self) private var signIn

    var body: some View {
        VStack(spacing: 0) {
            ProviderOnboardingTopBar(
                title: model.title,
                titleIdentifier: model.screen == .choice ? "localEngineProvidersTitle" : "providerOnboardingTitle",
                leading: model.canGoBack ? .back : .close,
                isEnabled: !model.isFinishing && !model.flow.isSaving,
                action: leaveScreen
            )
            ProviderColumn {
                SetupStepBar(step: 1, total: 2, identifier: "localEngineProvidersStep")
            }
            screen
                .id(model.screen)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preference(key: MacPanelCloseKey.self, value: MacPanelCloseOverride(hidden: true))
        .tracksProviderSignIns(model.providers)
        .onChange(of: model.providers.rows) { _, _ in Task { await model.signInSettled() } }
        .task(id: model.inlineSignInService) { signIn.answerInline(model.inlineSignInService.map { [$0] } ?? []) }
        .onDisappear { signIn.answerInline([]) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("localEngineProviders")
    }

    @ViewBuilder
    private var screen: some View {
        switch model.screen {
        case .choice, .morePlans, .moreKeys: ProviderChoiceScreen(model: model)
        case .signIn(let id): ProviderSignInScreen(model: model, providerID: id)
        case .claude(let id): ProviderClaudeScreen(model: model, providerID: id)
        case .key(let id): ProviderKeyScreen(model: model, providerID: id)
        case .local: ProviderLocalScreen(model: model)
        case .test(let id): ProviderTestScreen(model: model, providerID: id)
        }
    }

    private func leaveScreen() {
        let center = signIn
        Task {
            if case .signIn(let id) = model.screen {
                await model.cancelSignIn(id) { await center.notNow(for: $0) }
            } else if model.canGoBack {
                await model.back()
            } else {
                await model.skip()
            }
        }
    }
}
#endif
