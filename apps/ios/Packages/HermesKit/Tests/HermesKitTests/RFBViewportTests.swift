import CoreGraphics
import HermesRFB
import Testing

@Suite("RFB viewport")
struct RFBViewportTests {
    private func viewport() -> RFBViewport {
        RFBViewport(container: CGSize(width: 400, height: 800), remote: RFBSize(width: 1280, height: 720))
    }

    @Test("the desktop is fitted to the width and centred, leaving bars above and below")
    func fitted() {
        let frame = viewport().displayedFrame
        #expect(frame.width == 400)
        #expect(abs(frame.height - 225) < 0.001)
        #expect(abs(frame.minY - 287.5) < 0.001)
    }

    @Test("a touch in the letterbox bars maps to no desktop point")
    func letterbox() {
        #expect(viewport().remotePoint(forViewPoint: CGPoint(x: 200, y: 100)) == nil)
        #expect(viewport().remotePoint(forViewPoint: CGPoint(x: 200, y: 700)) == nil)
    }

    @Test("a letterbox touch can be clamped to the nearest desktop edge for a drag that wanders off")
    func clamped() throws {
        let point = try #require(viewport().remotePoint(forViewPoint: CGPoint(x: 500, y: 100), clampingToFrame: true))
        #expect(point.x == 1279)
        #expect(point.y == 0)
    }

    @Test("the centre of the container is the centre of the desktop")
    func centre() throws {
        let point = try #require(viewport().remotePoint(forViewPoint: CGPoint(x: 200, y: 400)))
        #expect(abs(point.x - 640) < 0.5)
        #expect(abs(point.y - 360) < 0.5)
    }

    @Test("zoom is clamped between one and the maximum")
    func zoomClamped() {
        var view = viewport()
        view.pinch(by: 100, around: CGPoint(x: 200, y: 400))
        #expect(view.zoom == RFBViewport.maximumZoom)
        view.pinch(by: 0.0001, around: CGPoint(x: 200, y: 400))
        #expect(view.zoom == 1)
        #expect(view.offset == .zero)
    }

    @Test("pinching keeps the desktop point under the fingers where it was")
    func pinchKeepsFocalPoint() throws {
        var view = viewport()
        let focal = CGPoint(x: 100, y: 380)
        let before = try #require(view.remotePoint(forViewPoint: focal))
        view.pinch(by: 5, around: focal)
        let after = try #require(view.remotePoint(forViewPoint: focal))
        #expect(abs(before.x - after.x) < 0.5)
        #expect(abs(before.y - after.y) < 0.5)
    }

    @Test("panning at the fit zoom does nothing")
    func panAtFit() {
        var view = viewport()
        view.pan(by: CGPoint(x: 50, y: 50))
        #expect(view.offset == .zero)
    }

    @Test("panning when zoomed stops at the desktop edges")
    func panClamped() {
        var view = viewport()
        view.pinch(by: 2, around: CGPoint(x: 200, y: 400))
        view.pan(by: CGPoint(x: 10_000, y: 10_000))
        #expect(view.offset.x == 200)
        #expect(view.offset.y == 0)
        view.pan(by: CGPoint(x: -10_000, y: -10_000))
        #expect(view.offset.x == -200)
    }

    @Test("a different desktop size or container re-fits and keeps the offset valid")
    func refit() {
        var view = viewport()
        view.pinch(by: 4, around: CGPoint(x: 200, y: 400))
        view.pan(by: CGPoint(x: -10_000, y: 0))
        view.update(container: CGSize(width: 400, height: 800), remote: RFBSize(width: 640, height: 480))
        let frame = view.displayedFrame
        #expect(frame.minX <= 0.001 || frame.width <= 400)
        #expect(frame.maxX >= 399.999 || frame.width <= 400)
    }

    @Test("a view point and its desktop point round-trip")
    func roundTrip() throws {
        var view = viewport()
        view.pinch(by: 2.5, around: CGPoint(x: 150, y: 350))
        let desktop = try #require(view.remotePoint(forViewPoint: CGPoint(x: 120, y: 380)))
        let back = view.viewPoint(forRemote: desktop)
        #expect(abs(back.x - 120) < 0.01)
        #expect(abs(back.y - 380) < 0.01)
    }
}
