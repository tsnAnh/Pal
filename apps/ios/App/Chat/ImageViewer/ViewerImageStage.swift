#if os(macOS)
import PalChat
import PalDesign
import SwiftUI

struct ViewerLoadedImage {
    let id: String
    let image: CGImage
}

struct ViewerContentView: View {
    let content: ViewerContent
    let state: ImageViewerState
    @Binding var loaded: ViewerLoadedImage?
    let step: (Int) -> Void

    var body: some View {
        switch content {
        case .image(let image):
            ViewerImageStage(image: image, state: state, loaded: $loaded, step: step)
        }
    }
}

private struct ViewerImageStage: View {
    let image: ConversationImage
    let state: ImageViewerState
    @Binding var loaded: ViewerLoadedImage?
    let step: (Int) -> Void

    var body: some View {
        ZStack {
            VStack(spacing: 10) {
                ChatImageSource(reference: image.reference, thumbnail: false, maxPixel: 4096) { phase, retry in
                    AnyView(ViewerImagePhase(phase: phase, image: image, loaded: $loaded, step: step, retry: retry))
                }
                .id(image.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
            .padding(.horizontal, 64)
            .padding(.bottom, 8)
            if state.showsStepper { arrows }
        }
    }

    private var footer: some View {
        VStack(spacing: 2) {
            if let loaded, loaded.id == image.id {
                Text(ViewerCaption.text(name: image.reference.name, pixelSize: pixelSize(of: loaded.image)))
                    .font(.system(size: 12))
                    .foregroundStyle(PalTokens.textTertiary)
                    .lineLimit(1)
                    .accessibilityIdentifier("imageViewerCaption")
            }
            if let position = state.positionLabel {
                Text(position)
                    .font(.system(size: 11))
                    .foregroundStyle(PalTokens.textTertiary)
                    .accessibilityIdentifier("imageViewerPosition")
            }
        }
        .frame(minHeight: 30)
    }

    private func pixelSize(of cgImage: CGImage) -> CGSize {
        ChatImageDecoder.originalSize(id: image.reference.id) ?? CGSize(width: cgImage.width, height: cgImage.height)
    }

    private var arrows: some View {
        GlassEffectContainer(spacing: 0) {
            HStack {
                arrow("chevron.left", label: "Previous image", identifier: "imageViewerPrevious", enabled: state.canGoPrevious, delta: -1)
                Spacer(minLength: 0)
                arrow("chevron.right", label: "Next image", identifier: "imageViewerNext", enabled: state.canGoNext, delta: 1)
            }
        }
        .padding(.horizontal, 12)
    }

    private func arrow(_ symbol: String, label: LocalizedStringKey, identifier: String, enabled: Bool, delta: Int) -> some View {
        PalClearGlassIconButton(systemName: symbol, label: label, identifier: identifier, diameter: 38) { step(delta) }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.35)
    }
}

private struct ViewerImagePhase: View {
    let phase: ChatImagePhase
    let image: ConversationImage
    @Binding var loaded: ViewerLoadedImage?
    let step: (Int) -> Void
    let retry: () -> Void

    var body: some View {
        switch phase {
        case .loading:
            preview
        case .loaded(let cgImage):
            ViewerZoomableImage(cgImage: cgImage, image: image, step: step)
                .task(id: ObjectIdentifier(cgImage)) { loaded = ViewerLoadedImage(id: image.id, image: cgImage) }
        case .failed(let message):
            failure(message)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let cgImage = ChatImageGrid.previewMaxPixels.lazy.compactMap({ ChatImageDecoder.cached(id: image.reference.id, maxPixel: $0) }).first {
            Image(platformImage: PlatformImage(cgImage: cgImage))
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("imageViewerPreview")
        } else {
            DelayedProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 10) {
            PalIcon("photo.badge.exclamationmark", ink: .secondary).font(.system(size: 32))
            Text(message).multilineTextAlignment(.center)
            Button(action: retry) {
                Text("Retry")
                    .font(.system(size: 13))
                    .foregroundStyle(PalTokens.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .palClearGlass(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("imageViewerRetry")
        }
        .foregroundStyle(PalTokens.textSecondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("imageViewerFailed")
    }
}

private struct ViewerZoomableImage: View {
    let cgImage: CGImage
    let image: ConversationImage
    let step: (Int) -> Void

    @State private var zoom = ViewerZoom()
    @State private var panBase = CGSize.zero
    @GestureState private var pinch: CGFloat = 1

    private static let swipeDistance: CGFloat = 60

    private var pixels: CGSize {
        ChatImageDecoder.originalSize(id: image.reference.id) ?? CGSize(width: cgImage.width, height: cgImage.height)
    }

    var body: some View {
        GeometryReader { proxy in
            let viewport = proxy.size
            let fitted = ViewerGeometry.fit(pixels, in: viewport)
            let shareable = Image(platformImage: PlatformImage(cgImage: cgImage))
            shareable
                .resizable()
                .frame(width: fitted.width, height: fitted.height)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 18, y: 6)
                .scaleEffect(min(max(zoom.scale * pinch, ViewerZoom.range.lowerBound), ViewerZoom.range.upperBound))
                .offset(zoom.offset)
                .position(x: viewport.width / 2, y: viewport.height / 2)
                .onTapGesture(count: 2) {
                    zoom.toggleActualSize(pixelSize: pixels, fitted: fitted)
                    panBase = zoom.offset
                }
                .gesture(magnify(fitted: fitted, viewport: viewport))
                .simultaneousGesture(drag(fitted: fitted, viewport: viewport))
                .contextMenu {
                    Button { ImageActions.copy(cgImage) } label: { Label("Copy", palIcon: "doc.on.doc") }
                        .accessibilityIdentifier("imageViewerCopy")
                    ShareLink(item: shareable, preview: SharePreview(image.reference.name, image: shareable))
                        .accessibilityIdentifier("imageViewerShare")
                }
                .accessibilityLabel(Text("Image \(image.reference.name)"))
                .accessibilityIdentifier("imageViewerImage")
        }
        .clipped()
    }

    private func magnify(fitted: CGSize, viewport: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, gesture, _ in gesture = value.magnification }
            .onEnded { value in
                zoom.magnify(by: value.magnification)
                zoom.pan(to: zoom.offset, fitted: fitted, viewport: viewport)
                panBase = zoom.offset
            }
    }

    private func drag(fitted: CGSize, viewport: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard zoom.isZoomed else { return }
                let proposed = CGSize(width: panBase.width + value.translation.width, height: panBase.height + value.translation.height)
                zoom.pan(to: proposed, fitted: fitted, viewport: viewport)
            }
            .onEnded { value in
                if zoom.isZoomed {
                    panBase = zoom.offset
                } else if abs(value.translation.width) >= Self.swipeDistance {
                    step(value.translation.width < 0 ? 1 : -1)
                }
            }
    }
}
#endif
