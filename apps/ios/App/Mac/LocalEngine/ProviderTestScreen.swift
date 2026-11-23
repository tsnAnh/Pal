#if os(macOS)
import PalBotProfile
import PalDesign
import SwiftUI

struct ProviderTestScreen: View {
    let model: ProviderOnboardingModel
    let providerID: String

    private var flow: ProviderTestFlow { model.flow }

    private var name: String { model.displayName(providerID) }

    private var plan: ProviderTestFooterPlan {
        ProviderTestFooterPlan.make(
            state: flow.state,
            options: ProviderTestFooterPlan.Options(
                isStaged: model.origin == .staged, keyed: flow.provider?.kind == .apiKey, canSignInAgain: flow.canSignInAgain,
                canChangeModel: flow.canChangeModelAfterFailure, canRemove: flow.canRemove))
    }

    private var face: ProviderTestFace {
        ProviderTestFace.make(
            state: flow.state, provider: name, model: model.selectedModel ?? "", savesOnContinue: model.origin == .staged)
    }

    var body: some View {
        let plan = plan
        ProviderScreen(
            content: {
                ScrollView {
                    ProviderColumn {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Pal sends one small message to be sure it works before saving.")
                                .hermesText(.botPreview)
                                .foregroundStyle(PalTokens.textSecondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 10)
                            ProviderCaption(title: String(localized: "Model"), identifier: "providerTestModelCaption")
                            ProviderModelList(model: model, providerID: providerID)
                            ProviderCaption(title: String(localized: "Connection"), identifier: "providerTestConnectionCaption")
                            ProviderTestCard(face: face, signedInTitle: signedInTitle, providerName: name)
                        }
                        .padding(.bottom, 16)
                    }
                }
                .scrollIndicators(.automatic)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("providerTest")
            },
            leading: { if let quiet = plan.quiet { button(for: quiet) } },
            trailing: {
                HStack(spacing: SetupFooterMetrics.mac.buttonSpacing) {
                    ForEach(plan.secondary, id: \.self) { action in button(for: action) }
                    button(for: plan.primary)
                }
            }
        )
    }

    private var signedInTitle: String {
        model.origin == .staged ? String(localized: "Key ready") : String(localized: "Signed in")
    }

    @ViewBuilder
    private func button(for action: ProviderTestAction) -> some View {
        if action == .skip {
            SetupQuietButton(title: action.title, identifier: action.identifier, action: handler(for: action))
                .disabled(isDisabled(action))
        } else {
            SetupButton(
                title: action.title, kind: action.isPrimary ? .primary : .secondary, isBusy: action == .testing,
                identifier: action.identifier, action: handler(for: action)
            )
            .disabled(isDisabled(action))
        }
    }

    private func isDisabled(_ action: ProviderTestAction) -> Bool {
        switch action {
        case .test, .retry, .testAgain: !model.canTest || model.isFinishing
        case .saveAndContinue: !flow.canSaveAndContinue || model.isFinishing
        case .cancel, .testing: false
        case .skip, .signInAgain, .changeKey, .changeModel, .remove: model.isFinishing || flow.isSaving
        }
    }

    private func handler(for action: ProviderTestAction) -> () -> Void {
        let model = model
        let handlers: [ProviderTestAction: () -> Void] = [
            .skip: { Task { await model.skip() } },
            .cancel: { model.cancelTest() },
            .test: { Task { await model.runTest() } },
            .retry: { Task { await model.runTest() } },
            .testAgain: { Task { await model.runTest() } },
            .saveAndContinue: { Task { await model.saveAndContinue() } },
            .signInAgain: { Task { await model.signInAgain() } },
            .changeKey: { model.changeKey() },
            .changeModel: { model.changeModel() },
            .remove: { Task { await model.removeProvider() } },
        ]
        return handlers[action] ?? {}
    }
}
#endif
