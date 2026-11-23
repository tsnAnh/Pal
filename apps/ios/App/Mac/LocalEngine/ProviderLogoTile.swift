#if os(macOS)
import PalDesign
import SwiftUI

struct ProviderLogoTile: View {
    private struct Logo {
        let asset: String
        let inset: CGFloat
    }

    private static let glyphInset: CGFloat = 6
    private static let portraitInset: CGFloat = 1
    private static let logos: [String: Logo] = [
        "anthropic": Logo(asset: "anthropic", inset: glyphInset),
        "openai-codex": Logo(asset: "openai", inset: glyphInset),
        "openai-api": Logo(asset: "openai", inset: glyphInset),
        "openrouter": Logo(asset: "openrouter", inset: glyphInset),
        "gemini": Logo(asset: "gemini", inset: glyphInset),
        "nous": Logo(asset: "nous", inset: portraitInset),
    ]

    let providerID: String
    let name: String

    var body: some View {
        Group {
            if let logo = Self.logos[providerID] {
                Image("ProviderLogos/\(logo.asset)")
                    .resizable()
                    .scaledToFit()
                    .padding(logo.inset)
            } else {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(PalTokens.textSecondary)
            }
        }
        .frame(width: 28, height: 28)
        .background(PalTokens.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }
}
#endif
