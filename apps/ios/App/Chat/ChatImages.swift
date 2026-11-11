import HermesChat
import HermesDesign
import ImageIO
import SwiftUI

typealias ChatImageLoader = @Sendable (ImageReference, _ thumbnail: Bool) async throws -> Data

private struct ChatImageLoaderKey: EnvironmentKey {
    static let defaultValue: ChatImageLoader? = nil
}

extension EnvironmentValues {
    var chatImageLoader: ChatImageLoader? {
        get { self[ChatImageLoaderKey.self] }
        set { self[ChatImageLoaderKey.self] = newValue }
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
    @State private var phase = ChatImagePhase.loading
    @State private var attempt = 0

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

    @State private var viewing: ImageReference?

    private static let single: CGFloat = 220
    private static let tile: CGFloat = 108
    private static let spacing: CGFloat = 4

    var body: some View {
        Group {
            if images.count == 1, let only = images.first {
                ChatImageTile(reference: only, width: Self.single, height: Self.single * 0.75) { viewing = only }
            } else {
                let columns = Array(repeating: GridItem(.fixed(Self.tile), spacing: Self.spacing), count: 2)
                LazyVGrid(columns: columns, alignment: .leading, spacing: Self.spacing) {
                    ForEach(images) { image in
                        ChatImageTile(reference: image, width: Self.tile, height: Self.tile) { viewing = image }
                    }
                }
                .frame(width: Self.tile * 2 + Self.spacing)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatImageGrid")
        #if os(iOS)
        .fullScreenCover(item: $viewing) { ChatImageViewer(reference: $0) }
        #else
        .sheet(item: $viewing) { ChatImageViewer(reference: $0) }
        #endif
    }
}

private struct ChatImageTile: View {
    let reference: ImageReference
    let width: CGFloat
    let height: CGFloat
    let open: () -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        ChatImageSource(reference: reference, thumbnail: true, maxPixel: Int(width * 3)) { phase, retry in
            AnyView(tile(phase, retry: retry))
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: HermesMetrics.cardRadius, style: .continuous))
    }

    @ViewBuilder
    private func tile(_ phase: ChatImagePhase, retry: @escaping () -> Void) -> some View {
        switch phase {
        case .loading:
            ZStack {
                Color(theme.palette.groupedCard)
                ProgressView().controlSize(.small)
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
                    Image(systemName: "photo.badge.exclamationmark").font(.system(size: 20))
                    Text(message).font(.caption2).multilineTextAlignment(.center).padding(.horizontal, 6)
                }
                .foregroundStyle(Color(theme.palette.textSecondary))
                .frame(width: width, height: height)
                .background(Color(theme.palette.groupedCard))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(message))
            .accessibilityIdentifier("chatImageFailed")
        }
    }
}

struct ChatImageViewer: View {
    let reference: ImageReference

    @Environment(\.dismiss) private var dismiss
    @Environment(\.hermesTheme) private var theme

    var body: some View {
        NavigationStack {
            ChatImageSource(reference: reference, thumbnail: false, maxPixel: 4096) { phase, retry in
                AnyView(content(phase, retry: retry))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(theme.palette.canvas))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() } label: { Text("Close") }
                        .accessibilityIdentifier("imageViewerClose")
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 900, minHeight: 360, idealHeight: 700)
        #endif
        .accessibilityIdentifier("imageViewer")
    }

    @ViewBuilder
    private func content(_ phase: ChatImagePhase, retry: @escaping () -> Void) -> some View {
        switch phase {
        case .loading:
            ProgressView()
        case .loaded(let image):
            Image(platformImage: PlatformImage(cgImage: image))
                .resizable()
                .scaledToFit()
                .padding()
                .accessibilityLabel(Text("Image \(reference.name)"))
                .accessibilityIdentifier("imageViewerImage")
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
