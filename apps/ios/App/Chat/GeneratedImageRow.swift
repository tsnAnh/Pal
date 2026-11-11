import PalChat
import PalDesign
import SwiftUI

struct GeneratedImageRow: View {
    let generation: ImageGeneration

    var body: some View {
        Group {
            switch generation {
            case .generating(let prompt, let shape):
                GeneratingImagePlaceholder(prompt: prompt, shape: shape)
            case .ready(let image):
                ChatImageGrid(images: [image])
            case .failed(let reason):
                FailedImageNotice(reason: reason)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .bubbleWidth(.leading)
    }
}

private enum GeneratedImageMetrics {
    static let width: CGFloat = 260
}

private struct GeneratingImagePlaceholder: View {
    let prompt: String?
    let shape: ImageGeneration.Shape

    @Environment(\.hermesTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        ZStack {
            Color(theme.palette.groupedCard)
                .opacity(dimmed ? 0.55 : 1)
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Creating an image")
                    .font(.footnote.weight(.medium))
                if let prompt {
                    Text(prompt)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 12)
                }
            }
            .foregroundStyle(Color(theme.palette.textSecondary))
        }
        .frame(width: GeneratedImageMetrics.width, height: GeneratedImageMetrics.width / shape.ratio)
        .clipShape(RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { dimmed = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(prompt.map { "Creating an image: \($0)" } ?? "Creating an image"))
        .accessibilityIdentifier("imageGenerationPlaceholder")
    }
}

private struct FailedImageNotice: View {
    let reason: String

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "photo.badge.exclamationmark")
            Text(reason)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color(theme.palette.textSecondary))
        .padding(12)
        .background(Color(theme.palette.groupedCard), in: RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("imageGenerationFailed")
    }
}
