#if os(macOS)
import AppKit
import Foundation
import Observation
import PalChat
import SwiftUI
import Testing

@testable import Pal

@MainActor
struct MacMediaViewerDismissTests {
    private struct TinyVideoSource: MediaAssetSource {
        func preview(_ reference: MediaReference) async throws -> MediaPreviewAnswer {
            .unavailable(reason: "none", MediaMetadata())
        }

        func chunk(_ reference: MediaReference, offset: Int, length: Int) async throws -> MediaChunk {
            MediaChunk(data: Data(repeating: 0, count: 16), offset: 0, total: 16)
        }
    }

    @Observable
    fileprivate final class Holder {
        var viewer: MediaViewerState?
    }

    fileprivate struct Harness: View {
        @Bindable var holder: Holder

        var body: some View {
            Color.clear.overlay { MacMediaViewerHost(viewer: $holder.viewer, source: TinyVideoSource()) }
        }
    }

    private func openViewer() throws -> MediaViewerState {
        let clips = [
            MediaReference(id: "v1", name: "first.mp4", kind: .video),
            MediaReference(id: "v2", name: "second.mp4", kind: .video),
        ]
        return try #require(ConversationMediaList.viewer(
            opening: clips[0], inRow: "r1", rows: [ConversationMediaRow(rowID: "r1", media: clips)]
        ))
    }

    private func spin(_ window: NSWindow, seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    fileprivate func mount(_ holder: Holder) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Harness(holder: holder))
        window.orderBack(nil)
        return window
    }

    @Test("closing the viewer while it is still loading does not trap", arguments: [0.0, 0.05, 1.5])
    func closeAfterOpening(settle: TimeInterval) throws {
        let holder = Holder()
        let window = mount(holder)
        holder.viewer = try openViewer()
        spin(window, seconds: settle)
        withAnimation(.easeOut(duration: 0.25)) { _ = MediaViewerState.close(&holder.viewer) }
        spin(window, seconds: 0.6)
        #expect(holder.viewer == nil)
        window.close()
    }

    @Test("closing twice in a row, then reopening and closing, does not trap")
    func closeTwiceThenReopen() throws {
        let holder = Holder()
        let window = mount(holder)
        holder.viewer = try openViewer()
        spin(window, seconds: 0.3)
        withAnimation(.easeOut(duration: 0.25)) { _ = MediaViewerState.close(&holder.viewer) }
        withAnimation(.easeOut(duration: 0.25)) { _ = MediaViewerState.close(&holder.viewer) }
        spin(window, seconds: 0.4)
        holder.viewer = try openViewer()
        spin(window, seconds: 0.3)
        withAnimation(.easeOut(duration: 0.25)) { _ = MediaViewerState.close(&holder.viewer) }
        spin(window, seconds: 0.6)
        #expect(holder.viewer == nil)
        window.close()
    }
}
#endif
