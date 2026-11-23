#if os(macOS)
import AppKit
import CoreGraphics
import Testing

@testable import Pal

@MainActor
@Suite("Computer frame delivery")
struct ComputerFrameDeliveryTests {
    private static func solidImage() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        return try #require(context.makeImage())
    }

    private static func onScreen(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.setFrameOrigin(NSScreen.screens.first?.frame.origin ?? .zero)
        window.orderFrontRegardless()
        return window
    }

    private static func settle(until condition: () -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("a frame submitted after the view is on screen becomes visible")
    func frameAfterBindIsShown() async throws {
        let image = try Self.solidImage()
        let sink = ComputerFrameSink()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let view = FrameImageView(frame: host.bounds)
        host.addSubview(view)
        let window = Self.onScreen(host)
        defer { window.orderOut(nil) }
        view.bind(sink)

        sink.submit(image)
        let shown = try await Self.settle { view.layer?.contents != nil }

        #expect(shown)
        #expect(!view.isHidden)
    }

    @Test("control: an already visible view shows the same frame")
    func controlVisibleViewShowsFrame() async throws {
        let image = try Self.solidImage()
        let sink = ComputerFrameSink()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let view = FrameImageView(frame: host.bounds)
        view.isHidden = false
        host.addSubview(view)
        let window = Self.onScreen(host)
        defer { window.orderOut(nil) }
        view.bind(sink)

        sink.submit(image)
        let shown = try await Self.settle { view.layer?.contents != nil }

        #expect(shown)
    }
}
#endif
