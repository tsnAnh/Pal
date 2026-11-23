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
        .onChange(of: model.providers.rows) { _, _ in model.signInSettled() }
        .task(id: model.providers.providerServiceKeys) { signIn.answerInline(model.providers.providerServiceKeys) }
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
        if case .signIn(let id) = model.screen {
            Task {
                await signIn.notNow(for: ModelProvidersClient.serviceKey + id)
                model.back()
            }
        } else if model.canGoBack {
            model.back()
        } else {
            Task { await model.skip() }
        }
    }
}
#endif
