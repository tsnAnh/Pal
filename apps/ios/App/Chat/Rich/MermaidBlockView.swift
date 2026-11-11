import HermesDesign
import SwiftUI

struct MermaidBlockView: View {
    let source: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var phase: Phase = .rendering

    private enum Phase {
        case rendering
        case drawn(MermaidImage)
        case failed
    }

    private struct RenderKey: Hashable {
        let source: String
        let isDark: Bool
    }

    var body: some View {
        content
            .task(id: RenderKey(source: source, isDark: colorScheme == .dark)) {
                await render(isDark: colorScheme == .dark)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .rendering:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 80)
                .accessibilityLabel("Drawing diagram")
        case .drawn(let image):
            VStack(alignment: .leading, spacing: 6) {
                diagram(image)
                Button("Copy source") { Pasteboard.string = source }
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
        case .failed:
            RichSourceFallback(source: source, note: "Could not draw this diagram", offersCopy: true)
        }
    }

    private func diagram(_ image: MermaidImage) -> some View {
        Image(platformImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: image.size.width, maxHeight: image.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Diagram")
            .accessibilityValue(source)
            .accessibilityAddTraits(.isImage)
    }

    private func render(isDark: Bool) async {
        if let cached = MermaidRenderer.shared.cachedImage(source: source, isDark: isDark) {
            phase = .drawn(cached)
            return
        }
        phase = .rendering
        do {
            phase = .drawn(try await MermaidRenderer.shared.render(source: source, isDark: isDark))
        } catch {
            phase = .failed
        }
    }
}

private extension Image {
    init(platformImage image: MermaidImage) {
        #if canImport(UIKit)
        self.init(uiImage: image)
        #else
        self.init(nsImage: image)
        #endif
    }
}
