import PalChat
import PalDesign
import SwiftUI

struct MediaGrid: View {
    let media: [MediaReference]

    @Environment(\.mediaOpener) private var opener
    @Environment(\.mediaRowID) private var rowID
    @FocusState private var focused: String?

    private static let spacing = MediaTileMetrics.spacing

    var body: some View {
        let videos = media.filter { $0.kind == .video }
        let audios = media.filter { $0.kind == .audio }
        VStack(alignment: .leading, spacing: Self.spacing) {
            if videos.count == 1, let only = videos.first {
                tile(only, width: MediaTileMetrics.single, height: MediaTileMetrics.singleHeight, followsPoster: true)
            } else if !videos.isEmpty {
                let columns = Array(repeating: GridItem(.fixed(MediaTileMetrics.tile), spacing: Self.spacing), count: 2)
                LazyVGrid(columns: columns, alignment: .leading, spacing: Self.spacing) {
                    ForEach(videos) { video in
                        tile(video, width: MediaTileMetrics.tile, height: MediaTileMetrics.tile)
                    }
                }
                .frame(width: MediaTileMetrics.tile * 2 + Self.spacing, alignment: .leading)
                #if os(macOS)
                .onMoveCommand { move($0, in: videos) }
                #endif
            }
            ForEach(audios) { audio in
                AudioBar(media: audio)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatMediaGrid")
    }

    @ViewBuilder
    private func tile(_ video: MediaReference, width: CGFloat, height: CGFloat, followsPoster: Bool = false) -> some View {
        let view = MediaTile(media: video, width: width, height: height, followsPoster: followsPoster)
        #if os(macOS)
        view
            .focusable()
            .focused($focused, equals: video.id)
            .contentShape(.focusEffect, RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
            .onKeyPress(.return) { open(video) }
            .onKeyPress(.space) { open(video) }
        #else
        view
        #endif
    }

    #if os(macOS)
    private func open(_ video: MediaReference) -> KeyPress.Result {
        opener?(video, rowID)
        return .handled
    }

    private func move(_ direction: MoveCommandDirection, in videos: [MediaReference]) {
        guard let current = videos.firstIndex(where: { $0.id == focused }) else { return }
        let step: Int
        switch direction {
        case .left: step = -1
        case .right: step = 1
        case .up: step = -2
        case .down: step = 2
        @unknown default: return
        }
        let target = current + step
        if videos.indices.contains(target) { focused = videos[target].id }
    }
    #endif
}
