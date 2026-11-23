#if os(macOS)
import PalBotProfile
import PalDesign
import SwiftUI

struct ProviderRow: View {
    static let minimumHeight: CGFloat = 54

    let provider: ModelProvider
    let name: String
    let blurb: String?
    let tag: String?
    let model: ProviderOnboardingModel

    private var key: String { "localEngineProvider-\(provider.id)" }

    private var isConnected: Bool { provider.state == .set }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: choose) {
                leading.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("\(key)-open")
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: Self.minimumHeight)
        .providerGlass()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(key)
    }

    private var leading: some View {
        HStack(spacing: 12) {
            ProviderLogo.tile(for: provider.id, name: name)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(name)
                        .hermesText(.rowTitle)
                        .foregroundStyle(PalTokens.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let tag {
                        Text(tag)
                            .hermesText(.timestamp)
                            .foregroundStyle(PalTokens.textTertiary)
                            .accessibilityIdentifier("\(key)-tag")
                    }
                }
                if let blurb, !blurb.isEmpty {
                    Text(blurb)
                        .hermesText(.botPreview)
                        .foregroundStyle(PalTokens.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isConnected {
            HStack(spacing: 6) {
                PalIcon("checkmark.circle.fill", ink: .success)
                Text("Connected")
                    .fontWeight(.semibold)
                    .hermesText(.botPreview)
                    .foregroundStyle(PalTokens.textPrimary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("\(key)-connected")
        } else {
            Button(action: choose) {
                Text(ProviderOnboardingModel.actionTitle(for: provider))
                    .hermesText(.botPreview)
                    .foregroundStyle(PalTokens.textPrimary)
            }
            .glassButtonStyle()
            .buttonBorderShape(.capsule)
            .accessibilityIdentifier("\(key)-action")
        }
    }

    private func choose() {
        Task { await model.choose(provider) }
    }
}

struct ProviderMoreRow: View {
    let title: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .hermesText(.rowTitle)
                    .foregroundStyle(PalTokens.textPrimary)
                Spacer(minLength: 0)
                PalIcon("chevron.right", ink: .tertiary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: ProviderRow.minimumHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .providerGlass()
        .accessibilityIdentifier(identifier)
    }
}
#endif
