#if os(macOS)
import PalBotProfile
import PalDesign
import PalProtocol
import SwiftUI

struct ProviderKeyScreen: View {
    let model: ProviderOnboardingModel
    let providerID: String

    @Environment(\.scenePhase) private var scenePhase
    @State private var text = ""

    private var name: String { model.displayName(providerID) }

    private var provider: ModelProvider? { model.providers.provider(id: providerID) }

    private var keyPage: String? {
        provider.flatMap { FirstRunProviders.choice(for: $0).keyPage }
    }

    private var prompt: String {
        provider?.acceptsSetupToken == true ? String(localized: "Paste your key or Claude plan token") : String(localized: "Paste your key")
    }

    private var hint: String {
        guard let keyPage else { return String(localized: "The key is kept in memory and only saved after the test passes.") }
        return String(localized: "Get a key at \(keyPage). The key is kept in memory and only saved after the test passes.")
    }

    var body: some View {
        ProviderScreen(
            content: {
                MacOverflowScroll {
                    ProviderColumn {
                        VStack(spacing: 0) {
                            ProviderHero(providerID: providerID, name: name, headline: String(localized: "Add your \(name) key"))
                            PalGlassTextField(
                                String(localized: "\(name) key"), text: $text, prompt: Text(prompt), isSecure: true,
                                identifier: "providerKeyField")
                                .privacySensitive()
                                .padding(.top, 24)
                            Text(hint)
                                .hermesText(.botPreview)
                                .foregroundStyle(PalTokens.textTertiary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 12)
                                .accessibilityIdentifier("providerKeyHint")
                        }
                    }
                }
            },
            leading: { },
            trailing: {
                HStack(spacing: SetupFooterMetrics.mac.buttonSpacing) {
                    SetupButton(title: String(localized: "Cancel"), kind: .secondary, identifier: "providerKeyCancel") {
                        text = ""
                        Task { await model.back() }
                    }
                    SetupButton(title: String(localized: "Continue"), kind: .primary, identifier: "providerKeyContinue", action: submit)
                        .disabled(SecretEntryInput.trimmed(text) == nil)
                }
            }
        )
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { text = "" }
        }
    }

    private func submit() {
        guard let value = SecretEntryInput.trimmed(text) else { return }
        text = ""
        model.continueWithKey(providerID, key: SecretString(value))
    }
}
#endif
