import PalChat
import PalDesign
import ImageIO
import SwiftUI

typealias ChatImageLoader = @Sendable (ImageReference, _ thumbnail: Bool) async throws -> Data

private struct ChatImageLoaderKey: EnvironmentKey {
    static let defaultValue: ChatImageLoader? = nil
}

private struct ChatImageOpenerKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: ((ImageReference) -> Void)? = nil
}

extension EnvironmentValues {
    var chatImageLoader: ChatImageLoader? {
        get { self[ChatImageLoaderKey.self] }
        set { self[ChatImageLoaderKey.self] = newValue }
    }

    var chatImageOpener: ((ImageReference) -> Void)? {
        get { self[ChatImageOpenerKey.self] }
        set { self[ChatImageOpenerKey.self] = newValue }
    }
}

nonisolated enum ChatImageDecoder {
    nonisolated(unsafe) private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    static func cached(id: String, maxPixel: Int) -> CGImage? {
        cache.object(forKey: key(id, maxPixel))
    }

    static func downsample(_ data: Data, id: String, maxPixel: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        cache.setObject(image, forKey: key(id, maxPixel), cost: image.width * image.height * 4)
        return image
    }

    private static func key(_ id: String, _ maxPixel: Int) -> NSString {
        "\(id)#\(maxPixel)" as NSString
    }
}

private enum ChatImagePhase {
    case loading
    case loaded(CGImage)
    case failed(String)
}

private struct ChatImageSource: View {
    let reference: ImageReference
    let thumbnail: Bool
    let maxPixel: Int
    let content: (ChatImagePhase, _ retry: @escaping () -> Void) -> AnyView

    @Environment(\.chatImageLoader) private var loader
    @State private var phase: ChatImagePhase
    @State private var attempt = 0

    init(
        reference: ImageReference, thumbnail: Bool, maxPixel: Int,
        content: @escaping (ChatImagePhase, _ retry: @escaping () -> Void) -> AnyView
    ) {
        self.reference = reference
        self.thumbnail = thumbnail
        self.maxPixel = maxPixel
        self.content = content
        _phase = State(initialValue: ChatImageDecoder.cached(id: reference.id, maxPixel: maxPixel).map(ChatImagePhase.loaded) ?? .loading)
    }

    var body: some View {
        content(phase) { attempt += 1 }
            .task(id: "\(reference.id)#\(attempt)") { await load() }
    }

    private func load() async {
        if let hit = ChatImageDecoder.cached(id: reference.id, maxPixel: maxPixel) {
            phase = .loaded(hit)
            return
        }
        guard let loader else {
            phase = .failed(ImageLoadFailure(reason: "Images aren't available here.").message)
            return
        }
        phase = .loading
        do {
            let data = try await loader(reference, thumbnail)
            let id = reference.id
            let size = maxPixel
            let image = await Task.detached(priority: .utility) { ChatImageDecoder.downsample(data, id: id, maxPixel: size) }.value
            phase = image.map(ChatImagePhase.loaded) ?? .failed(ImageLoadFailure(reason: "The image file is damaged.").message)
        } catch is CancellationError {
        } catch {
            phase = .failed(ImageLoadFailure(describing: error).message)
        }
    }
}

struct ChatImageGrid: View {
    let images: [ImageReference]

    @Environment(\.chatImageOpener) private var opener

    private static let single: CGFloat = 220
    private static let tile: CGFloat = 108
    private static let spacing: CGFloat = 4

    var body: some View {
        Group {
            if images.count == 1, let only = images.first {
                ChatImageTile(reference: only, width: Self.single, height: Self.single * 0.75) { opener?(only) }
            } else {
                let columns = Array(repeating: GridItem(.fixed(Self.tile), spacing: Self.spacing), count: 2)
                LazyVGrid(columns: columns, alignment: .leading, spacing: Self.spacing) {
                    ForEach(images) { image in
                        ChatImageTile(reference: image, width: Self.tile, height: Self.tile) { opener?(image) }
                    }
                }
                .frame(width: Self.tile * 2 + Self.spacing)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatImageGrid")
    }
}

private struct ChatImageTile: View {
    let reference: ImageReference
    let width: CGFloat
    let height: CGFloat
    let open: () -> Void

    var body: some View {
        ChatImageSource(reference: reference, thumbnail: true, maxPixel: Int(width * 3)) { phase, retry in
            AnyView(tile(phase, retry: retry))
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
    }

    @ViewBuilder
    private func tile(_ phase: ChatImagePhase, retry: @escaping () -> Void) -> some View {
        switch phase {
        case .loading:
            ZStack {
                PalTokens.agentBubble
                DelayedProgressView(after: ChatEdgeFade.loadingDelay).controlSize(.small).tint(PalTokens.textTertiary)
            }
            .accessibilityIdentifier("chatImageLoading")
        case .loaded(let image):
            Button(action: open) {
                Image(platformImage: PlatformImage(cgImage: image))
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Image \(reference.name). Tap to enlarge"))
            .accessibilityIdentifier("chatImage")
        case .failed(let message):
            Button(action: retry) {
                VStack(spacing: 4) {
                    Image(systemName: "photo")
                        .font(.system(size: 17))
                        .foregroundStyle(PalTokens.textTertiary)
                    Text("Couldn't load · Retry")
                        .hermesText(.timestamp)
                        .foregroundStyle(PalTokens.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .frame(width: width, height: height)
                .background(PalTokens.agentBubble)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(message))
            .accessibilityIdentifier("chatImageFailed")
        }
    }
}

struct ChatImageViewer: View {
    let model: ChatModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.hermesTheme) private var theme
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @FocusState private var focused: Bool

    private static let swipeDistance: CGFloat = 60

    var body: some View {
        NavigationStack {
            Group {
                if let state = model.imageViewer { stage(state) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(theme.palette.canvas))
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() } label: { Text("Close") }
                        .accessibilityIdentifier("imageViewerClose")
                }
            }
            .iOSOnly { $0.toolbarTitleDisplayMode(.inline) }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { go(-1) }
        .onKeyPress(.rightArrow) { go(1) }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .accessibilityIdentifier("imageViewer")
    }

    private var title: String {
        guard let state = model.imageViewer else { return "" }
        return String(localized: "\(state.index + 1) of \(state.images.count)")
    }

    private func stage(_ state: ImageViewerState) -> some View {
        let reference = state.current.reference
        return ChatImageSource(reference: reference, thumbnail: false, maxPixel: 4096) { phase, retry in
            AnyView(content(phase, reference: reference, retry: retry))
        }
        .id(state.current.id)
        .scaleEffect(min(max(zoom * pinch, 1), 6))
        .gesture(
            MagnifyGesture()
                .updating($pinch) { value, gesture, _ in gesture = value.magnification }
                .onEnded { zoom = min(max(zoom * $0.magnification, 1), 6) }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: Self.swipeDistance).onEnded { drag in
                guard zoom <= 1 else { return }
                _ = go(drag.translation.width < 0 ? 1 : -1)
            }
        )
        .onChange(of: state.current.id) { zoom = 1 }
        .overlay { stepButtons(state) }
    }

    private func stepButtons(_ state: ImageViewerState) -> some View {
        HStack {
            Button { _ = go(-1) } label: {
                Image(systemName: "chevron.left.circle.fill").font(.system(size: 32))
            }
            .disabled(!state.canGoPrevious)
            .accessibilityLabel(Text("Previous image"))
            .accessibilityIdentifier("imageViewerPrevious")
            Spacer()
            Button { _ = go(1) } label: {
                Image(systemName: "chevron.right.circle.fill").font(.system(size: 32))
            }
            .disabled(!state.canGoNext)
            .accessibilityLabel(Text("Next image"))
            .accessibilityIdentifier("imageViewerNext")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(theme.palette.textSecondary))
        .padding(.horizontal, 12)
    }

    private func go(_ step: Int) -> KeyPress.Result {
        if step < 0 { model.imageViewer?.goPrevious() } else { model.imageViewer?.goNext() }
        return .handled
    }

    @ToolbarContentBuilder
    private func imageActions(for image: CGImage, reference: ImageReference) -> some ToolbarContent {
        let shareable = Image(platformImage: PlatformImage(cgImage: image))
        ToolbarItemGroup(placement: .primaryAction) {
            ShareLink(item: shareable, preview: SharePreview(reference.name, image: shareable))
                .accessibilityIdentifier("imageViewerShare")
            Button { ImageActions.copy(image) } label: { Label("Copy", systemImage: "doc.on.doc") }
                .accessibilityIdentifier("imageViewerCopy")
            #if os(macOS)
            Button { ImageActions.save(image, suggestedName: reference.name) } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .accessibilityIdentifier("imageViewerSave")
            #endif
        }
    }

    @ViewBuilder
    private func content(_ phase: ChatImagePhase, reference: ImageReference, retry: @escaping () -> Void) -> some View {
        switch phase {
        case .loading:
            DelayedProgressView()
        case .loaded(let image):
            Image(platformImage: PlatformImage(cgImage: image))
                .resizable()
                .scaledToFit()
                .padding()
                .accessibilityLabel(Text("Image \(reference.name)"))
                .accessibilityIdentifier("imageViewerImage")
                .toolbar { imageActions(for: image, reference: reference) }
        case .failed(let message):
            Button(action: retry) {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark").font(.system(size: 32))
                    Text(message).multilineTextAlignment(.center)
                }
                .foregroundStyle(Color(theme.palette.textSecondary))
                .padding()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("imageViewerFailed")
        }
    }
}
