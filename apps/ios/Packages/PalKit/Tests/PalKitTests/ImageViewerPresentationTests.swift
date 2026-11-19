@testable import PalChat
import CoreGraphics
import Foundation
import Testing

@Suite("Image viewer presentation")
struct ImageViewerPresentationTests {
    private func host(_ name: String) -> ImageReference { ImageReference(source: .hostPath("/h/cache/images/\(name)")) }

    private func state(count: Int, opening: Int = 0, text: String? = nil) throws -> ImageViewerState {
        let images = ConversationImages.list(from: [
            .init(rowID: "a1", text: text, images: (0..<count).map { host("cover-\($0).png") })
        ])
        return try #require(ImageViewerState(images: images, opening: images[opening].id, anchorRowID: "a1"))
    }

    @Test("a named image titles itself; a generic name falls back to the message's first line")
    func titleChoice() {
        #expect(ViewerTitle.choose(name: "set-v5-contact.png", messageText: "Here you go") == "set-v5-contact.png")
        #expect(ViewerTitle.choose(name: "image.png", messageText: "\n  Crop this to the horizon?\nthanks") == "Crop this to the horizon?")
        #expect(ViewerTitle.choose(name: "IMG_2041.HEIC", messageText: "Crop it") == "Crop it")
        #expect(ViewerTitle.choose(name: "6f1c2a9e-3b7d-4c11-9a0e-5d2f8b7c1a44.png", messageText: "Look") == "Look")
        #expect(ViewerTitle.choose(name: "photo-1731000000.jpg", messageText: "Look") == "Look")
        #expect(ViewerTitle.choose(name: "image", messageText: nil) == "image")
        #expect(ViewerTitle.choose(name: "image.png", messageText: "  \n ") == "image.png")
    }

    @Test("the generic-name test keeps descriptive names")
    func genericTest() {
        for name in ["image.png", "Image 3.png", "Screenshot 2026-11-05 at 10.00.00 AM.png", "IMG_0001.jpg", "a1b2c3d4e5f60718.png", "2041.png"] {
            #expect(ViewerTitle.isGeneric(name), "\(name)")
        }
        for name in ["contact-sheet.png", "cover-b.png", "image-of-a-cat.png", "set-v5-contact.png"] {
            #expect(!ViewerTitle.isGeneric(name), "\(name)")
        }
    }

    @Test("the caption names the file and its pixel size")
    func caption() {
        #expect(ViewerCaption.text(name: "set-v5-contact.png", pixelSize: CGSize(width: 1280, height: 2048)) == "set-v5-contact.png · 1280 × 2048")
        #expect(ViewerCaption.text(name: "a.png", pixelSize: nil) == "a.png")
        #expect(ViewerCaption.text(name: "a.png", pixelSize: .zero) == "a.png")
    }

    @Test("one image shows no stepper; several show the position and dim the ends")
    func stepState() throws {
        let single = try state(count: 1)
        #expect(!single.showsStepper)
        #expect(single.positionLabel == nil)
        #expect(!single.canGoPrevious && !single.canGoNext)

        var several = try state(count: 5, opening: 1)
        #expect(several.showsStepper)
        #expect(several.positionLabel == "2 of 5")
        #expect(several.canGoPrevious && several.canGoNext)
        several.goPrevious()
        #expect(!several.canGoPrevious)
        #expect(several.positionLabel == "1 of 5")
        for _ in 0..<10 { several.goNext() }
        #expect(!several.canGoNext)
        #expect(several.positionLabel == "5 of 5")
    }

    @Test("the viewer title comes from the current image's message when its name is generic")
    func stateTitle() throws {
        let generic = ConversationImages.list(from: [.init(rowID: "u1", text: "Make it warmer\nplease", images: [host("image.png")])])
        let viewer = try #require(ImageViewerState(images: generic, opening: generic[0].id, anchorRowID: "u1"))
        #expect(viewer.title == "Make it warmer")
        #expect(try state(count: 2).title == "cover-0.png")
    }

    @Test("an image offers edit, download and close")
    func actions() throws {
        #expect(try state(count: 1).content.actions == [.edit, .download, .close])
    }

    @Test("zoom clamps to 1x through 6x and drops the pan when back at fit")
    func zoomClamp() {
        var zoom = ViewerZoom()
        zoom.magnify(by: 100)
        #expect(zoom.scale == 6)
        zoom.pan(to: CGSize(width: 50, height: 0), fitted: CGSize(width: 400, height: 300), viewport: CGSize(width: 400, height: 300))
        #expect(zoom.offset.width == 50)
        zoom.magnify(by: 0.001)
        #expect(zoom.scale == 1)
        #expect(zoom.offset == .zero)
    }

    @Test("tall and wide images both fit inside the box with their aspect kept")
    func fit() {
        let box = CGSize(width: 600, height: 400)
        #expect(ViewerGeometry.fit(CGSize(width: 1280, height: 2048), in: box) == CGSize(width: 250, height: 400))
        #expect(ViewerGeometry.fit(CGSize(width: 1920, height: 1080), in: box) == CGSize(width: 600, height: 337.5))
        #expect(ViewerGeometry.fit(.zero, in: box) == .zero)
    }

    @Test("pan stays inside the zoomed image")
    func panLimit() {
        var zoom = ViewerZoom()
        zoom.setScale(2)
        zoom.pan(to: CGSize(width: 999, height: -999), fitted: CGSize(width: 400, height: 300), viewport: CGSize(width: 400, height: 300))
        #expect(zoom.offset == CGSize(width: 200, height: -150))
        zoom.setScale(1)
        zoom.pan(to: CGSize(width: 10, height: 10), fitted: CGSize(width: 400, height: 300), viewport: CGSize(width: 400, height: 300))
        #expect(zoom.offset == .zero)
    }

    @Test("double-click toggles fit and actual size")
    func doubleClick() {
        var zoom = ViewerZoom()
        let fitted = CGSize(width: 500, height: 400)
        zoom.toggleActualSize(pixelSize: CGSize(width: 2000, height: 1600), fitted: fitted)
        #expect(zoom.scale == 4)
        zoom.toggleActualSize(pixelSize: CGSize(width: 2000, height: 1600), fitted: fitted)
        #expect(zoom.scale == 1)
        zoom.toggleActualSize(pixelSize: CGSize(width: 9000, height: 7200), fitted: fitted)
        #expect(zoom.scale == 6)
        zoom.reset()
        zoom.toggleActualSize(pixelSize: CGSize(width: 300, height: 240), fitted: fitted)
        #expect(zoom.scale == ViewerZoom.doubleClickMinimum)
    }

    @Test("edit attaches the image and sets the hint and asks for focus")
    func editAction() throws {
        let viewer = try state(count: 3, opening: 1)
        var composer = ViewerComposerState()
        #expect(composer.placeholder(title: "cover-1.png") == "Message about “cover-1.png”")
        composer.edit(viewer.current)
        #expect(composer.attachedImageID == viewer.current.id)
        #expect(composer.placeholder(title: "cover-1.png") == "Describe the change")
        #expect(composer.focusRequests == 1)
        composer.edit(viewer.current)
        #expect(composer.focusRequests == 2)
    }

    @Test("sending from the viewer composer sends the current image with the text and closes the viewer")
    func sendClosesViewer() throws {
        let viewer = try state(count: 3, opening: 2)
        var composer = ViewerComposerState()
        composer.draft = "  warmer please \n"
        let sent = try #require(ImageViewerSend.submit(viewer, composer: composer))
        #expect(sent.submission.image == viewer.current)
        #expect(sent.submission.text == "warmer please")
        #expect(sent.viewer == nil)
    }

    @Test("an image attached with Edit stays the one sent after stepping to another image")
    func sendKeepsEditedImage() throws {
        var viewer = try state(count: 3, opening: 0)
        var composer = ViewerComposerState()
        composer.edit(viewer.current)
        let edited = viewer.current
        viewer.goNext()
        #expect(try #require(ImageViewerSend.submit(viewer, composer: composer)).submission.image == edited)
    }
}
