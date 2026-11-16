@testable import PalChat
import Foundation
import Testing

@Suite("Conversation image list and viewer")
struct ConversationImagesTests {
    private func host(_ name: String) -> ImageReference { ImageReference(source: .hostPath("/h/cache/images/\(name)")) }

    private func list() -> [ConversationImage] {
        ConversationImages.list(from: [
            (rowID: "u1", images: [host("a.png"), host("b.png")]),
            (rowID: "a1", images: [ImageReference(source: .remote(URL(string: "https://example.com/c.png")!))]),
            (rowID: "g1", images: [ImageReference(source: .inline(Data([1, 2, 3])))]),
        ])
    }

    @Test("every row's images join one list in transcript order with row-scoped ids")
    func orderAndIDs() {
        let images = list()
        #expect(images.map(\.reference.name) == ["a.png", "b.png", "c.png", "image"])
        #expect(Set(images.map(\.id)).count == 4)
        #expect(images.first?.id.hasPrefix("u1/") == true)
    }

    @Test("the same photo in two messages keeps two entries")
    func sameImageTwice() {
        let images = ConversationImages.list(from: [(rowID: "u1", images: [host("a.png")]), (rowID: "a1", images: [host("a.png")])])
        #expect(images.count == 2)
        #expect(images[0].id != images[1].id)
    }

    @Test("an image without a loadable reference is skipped")
    func skipsUnloadable() {
        let images = ConversationImages.list(from: [
            (rowID: "r", images: [
                ImageReference(source: .hostPath("  ")),
                ImageReference(source: .remote(URL(string: "http://example.com/x.png")!)),
                ImageReference(source: .inline(Data())),
                host("ok.png"),
            ]),
        ])
        #expect(images.map(\.reference.name) == ["ok.png"])
    }

    @Test("opening at an id lands on its index and an unknown id does not open")
    func opens() {
        let images = list()
        #expect(ImageViewerState(images: images, opening: images[2].id, anchorRowID: "a1")?.index == 2)
        #expect(ImageViewerState(images: images, opening: "missing", anchorRowID: "a1") == nil)
    }

    @Test("next and previous stop at the ends instead of wrapping")
    func bounds() throws {
        let images = list()
        var state = try #require(ImageViewerState(images: images, opening: images[0].id, anchorRowID: "u1"))
        #expect(!state.canGoPrevious && state.canGoNext)
        state.goPrevious()
        #expect(state.index == 0)
        for _ in 0..<10 { state.goNext() }
        #expect(state.index == images.count - 1)
        #expect(state.canGoPrevious && !state.canGoNext)
        state.goPrevious()
        #expect(state.current.id == images[images.count - 2].id)
    }

    @Test("navigating never moves the transcript anchor the viewer was opened from")
    func anchorStays() throws {
        let images = list()
        var state = try #require(ImageViewerState(images: images, opening: images[1].id, anchorRowID: "u1"))
        state.goNext()
        state.goNext()
        #expect(state.anchorRowID == "u1")
    }

    @Test("QuickLook-class types preview and the rest fall back to save")
    func previewDecision() {
        for name in ["a.pdf", "b.DOCX", "c.xlsx", "d.pptx", "e.txt", "f.swift", "g.png", "h.mov", "i.mp3", "j.json"] {
            #expect(FilePreviewKind(fileName: name) == .quickLook, "\(name)")
        }
        for name in ["a.zip", "b.dmg", "c.bin", "noextension", "d.tar.gz", "e.exe"] {
            #expect(FilePreviewKind(fileName: name) == .saveOnly, "\(name)")
        }
    }
}
