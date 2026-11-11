import HermesChat
import SwiftUI

struct EmbedCardView: View {
    let descriptor: EmbedDescriptor

    @Environment(\.colorScheme) private var colorScheme
    @State private var store = EmbedConsentStore.shared
    @State private var failed = false

    private static let defaultHeight: CGFloat = 320

    var body: some View {
        Group {
            if failed {
                failureState
            } else if store.permits(descriptor) {
                sized(EmbedWebView(descriptor: descriptor, dark: colorScheme == .dark, onFailure: { failed = true }))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel("\(descriptor.label) embed")
            } else {
                consentPlaceholder
            }
        }
        .frame(maxWidth: descriptor.maxWidth.map { CGFloat($0) } ?? .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func sized<Content: View>(_ content: Content) -> some View {
        if let ratio = descriptor.aspectRatio, ratio > 0 {
            content.aspectRatio(CGFloat(ratio), contentMode: .fit)
        } else {
            content.frame(height: CGFloat(descriptor.height ?? Double(Self.defaultHeight)))
        }
    }

    private var hostLabel: String {
        if descriptor.provider == .twitter { return "x.com" }
        let host = descriptor.sourceURL.host(percentEncoded: false) ?? descriptor.label
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private var consentPlaceholder: some View {
        sized(
            VStack(spacing: 8) {
                Button {
                    store.loadOnce(descriptor)
                } label: {
                    Label("Load \(descriptor.label)", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                Button("Always allow \(descriptor.label)") {
                    store.allowAlways(descriptor.provider)
                }
                .buttonStyle(.bordered)
                Text(hostLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                openInBrowserButton
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }

    private var failureState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This embed could not load.")
                .font(.subheadline)
            openInBrowserButton
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var openInBrowserButton: some View {
        Button("Open in browser") {
            ExternalLink.open(descriptor.sourceURL)
        }
        .font(.caption)
        .buttonStyle(.borderless)
    }
}
