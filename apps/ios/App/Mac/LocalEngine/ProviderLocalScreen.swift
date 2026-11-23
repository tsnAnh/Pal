#if os(macOS)
import PalBotProfile
import PalDesign
import PalProtocol
import SwiftUI

struct ProviderLocalScreen: View {
    let model: ProviderOnboardingModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var address = ""
    @State private var key = ""

    private var provider: ModelProvider? { model.providers.provider(id: FirstRunProviders.localProviderID) }

    var body: some View {
        ProviderScreen(
            content: {
                MacOverflowScroll {
                    ProviderColumn {
                        VStack(spacing: 12) {
                            ProviderHero(
                                providerID: FirstRunProviders.localProviderID, name: String(localized: "Local or custom address"),
                                headline: String(localized: "Local or custom address"),
                                detail: String(localized: "Ollama, LM Studio, or any OpenAI-compatible server."))
                            fields
                                .padding(.top, 12)
                            Text("Pal reads the models from the server on the next screen. Nothing is saved until the test passes.")
                                .hermesText(.botPreview)
                                .foregroundStyle(PalTokens.textTertiary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("providerLocalHint")
                        }
                    }
                }
            },
            leading: { },
            trailing: {
                HStack(spacing: SetupFooterMetrics.mac.buttonSpacing) {
                    SetupButton(title: String(localized: "Cancel"), kind: .secondary, identifier: "providerLocalCancel") {
                        key = ""
                        model.back()
                    }
                    SetupButton(title: String(localized: "Continue"), kind: .primary, identifier: "providerLocalContinue", action: submit)
                        .disabled(LocalAddress.normalized(address) == nil)
                }
            }
        )
        .task { if address.isEmpty, let provider { address = model.providers.address(for: provider) } }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { key = "" }
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldCaption(String(localized: "Address"))
            PalGlassTextField(
                String(localized: "Address"), text: $address, prompt: Text(verbatim: "http://localhost:11434/v1"),
                identifier: "providerLocalAddress")
            fieldCaption(String(localized: "Key (optional)"))
                .padding(.top, 6)
            PalGlassTextField(
                String(localized: "Key (optional)"), text: $key, prompt: Text("Only if your server asks for one"), isSecure: true,
                identifier: "providerLocalKey")
                .privacySensitive()
        }
    }

    private func fieldCaption(_ title: String) -> some View {
        Text(title)
            .fontWeight(.semibold)
            .hermesText(.timestamp)
            .foregroundStyle(PalTokens.textSecondary)
            .padding(.leading, 2)
    }

    private func submit() {
        guard let value = LocalAddress.normalized(address) else { return }
        let secret = SecretEntryInput.trimmed(key).map(SecretString.init)
        key = ""
        model.continueWithLocal(address: value, key: secret)
    }
}
#endif
