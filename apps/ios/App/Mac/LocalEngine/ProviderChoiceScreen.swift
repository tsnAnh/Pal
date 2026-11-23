#if os(macOS)
import PalBotProfile
import PalDesign
import SwiftUI

struct ProviderChoiceScreen: View {
    let model: ProviderOnboardingModel

    var body: some View {
        if !model.providers.hasLoaded && model.providers.loadFailed {
            ProviderLoadFailureScreen(model: model)
        } else {
            ProviderScreen(
                content: { content },
                leading: { skipButton },
                trailing: { continueButton }
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.providers.hasLoaded {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.top, 28)
                .accessibilityIdentifier("localEngineProvidersLoading")
        } else {
            VStack(spacing: 0) {
                header
                list
            }
        }
    }

    private var header: some View {
        @Bindable var model = model
        return ProviderColumn {
            VStack(spacing: 12) {
                if model.screen == .choice {
                    Text("Sign in with a plan you already pay for, or use a key.")
                        .hermesText(.botPreview)
                        .foregroundStyle(PalTokens.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                ClearGlassSearchField(
                    text: $model.searchText, prompt: String(localized: "Search providers"),
                    accessibilityLabel: String(localized: "Search providers"), accessibilityIdentifier: "localEngineProvidersSearch"
                )
            }
            .padding(.top, 10)
        }
    }

    private var list: some View {
        ScrollView {
            ProviderColumn {
                LazyVStack(alignment: .leading, spacing: 8) {
                    rows
                }
                .padding(.bottom, 16)
            }
        }
        .scrollIndicators(.automatic)
    }

    private var isSearching: Bool {
        !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var rows: some View {
        switch model.screen {
        case .morePlans: providerRows(FirstRunProviders.filter(model.providers.layout.morePlans, query: model.searchText))
        case .moreKeys: providerRows(FirstRunProviders.filter(model.providers.layout.moreKeys, query: model.searchText))
        default: if isSearching { providerRows(model.searchResults) } else { groups }
        }
    }

    @ViewBuilder
    private func providerRows(_ providers: [ModelProvider]) -> some View {
        if providers.isEmpty {
            Text(ModelProvidersModel.noMatchText)
                .hermesText(.botPreview)
                .foregroundStyle(PalTokens.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
                .accessibilityIdentifier("localEngineProvidersNoMatch")
        } else {
            ForEach(providers) { provider in
                let choice = FirstRunProviders.choice(for: provider)
                ProviderRow(provider: provider, name: choice.name, blurb: choice.blurb, tag: choice.tag, model: model)
            }
        }
    }

    @ViewBuilder
    private var groups: some View {
        let layout = model.providers.layout
        if !layout.subscriptions.isEmpty || !layout.morePlans.isEmpty {
            ProviderCaption(
                title: String(localized: "Subscriptions"),
                subtitle: String(localized: "Sign in with an existing plan. No key, no extra bill."), identifier: "providerGroupSubscriptions")
            ForEach(layout.subscriptions) { choice in
                ProviderRow(provider: choice.provider, name: choice.name, blurb: choice.blurb, tag: choice.tag, model: model)
            }
            if !layout.morePlans.isEmpty {
                ProviderMoreRow(title: String(localized: "More plans"), identifier: "localEngineProvidersMorePlans") { model.push(.morePlans) }
            }
        }
        if !layout.keys.isEmpty || !layout.moreKeys.isEmpty {
            ProviderCaption(title: String(localized: "API keys"), identifier: "providerGroupKeys")
            ForEach(layout.keys) { choice in
                ProviderRow(provider: choice.provider, name: choice.name, blurb: choice.blurb, tag: choice.tag, model: model)
            }
            if !layout.moreKeys.isEmpty {
                ProviderMoreRow(title: String(localized: "More providers"), identifier: "localEngineProvidersMore") { model.push(.moreKeys) }
            }
        }
        if let local = layout.local {
            ProviderCaption(title: String(localized: "On this Mac or your own server"), identifier: "providerGroupLocal")
            ProviderRow(
                provider: local, name: String(localized: "Local or custom address"),
                blurb: String(localized: "Ollama, LM Studio, any OpenAI-compatible server"), tag: nil, model: model)
        }
    }

    private var skipButton: some View {
        SetupQuietButton(title: String(localized: "Skip for now"), identifier: "localEngineProvidersSkip") {
            Task { await model.skip() }
        }
        .disabled(model.isFinishing)
    }

    private var continueButton: some View {
        SetupButton(title: String(localized: "Continue"), kind: .primary, identifier: "localEngineProvidersContinue") {
            model.continueToTest()
        }
        .disabled(!model.providers.hasConnectedProvider || model.isFinishing)
    }
}

struct ProviderLoadFailureScreen: View {
    let model: ProviderOnboardingModel

    var body: some View {
        ProviderScreen(
            content: {
                VStack(spacing: 10) {
                    BrandLogoTile(symbol: "exclamationmark.triangle", size: .hero)
                    Text("Could not load providers")
                        .fontWeight(.semibold)
                        .hermesText(.sheetTitle)
                        .foregroundStyle(PalTokens.textPrimary)
                        .padding(.top, 6)
                        .accessibilityIdentifier("localEngineProvidersFailureTitle")
                    Text("Pal on this Mac did not answer. It may still be starting.")
                        .hermesText(.botPreview)
                        .foregroundStyle(PalTokens.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("localEngineProvidersFailure")
            },
            leading: {
                SetupQuietButton(title: String(localized: "Skip for now"), identifier: "localEngineProvidersSkip") {
                    Task { await model.skip() }
                }
                .disabled(model.isFinishing)
            },
            trailing: {
                SetupButton(title: String(localized: "Try again"), kind: .primary, isBusy: model.providers.isLoading, identifier: "localEngineProvidersRetry") {
                    Task { await model.providers.load() }
                }
            }
        )
    }
}
#endif
