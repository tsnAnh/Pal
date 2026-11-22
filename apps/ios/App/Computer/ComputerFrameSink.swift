import CoreGraphics
import PalDiagnostics
import QuartzCore
#if os(macOS)
import AppKit
#endif

@MainActor
final class ComputerFrameSink {
    private(set) var latest: CGImage?
    private(set) var generation = 0
    var onFrame: (() -> Void)?

    func submit(_ image: CGImage) {
        latest = image
        generation += 1
        PalPerf.event("computer.frame.submitted")
        onFrame?()
    }
}

@MainActor
final class ComputerFrameDelivery: NSObject {
    private let show: (CGImage) -> Void
    private var sink: ComputerFrameSink?
    private var link: CADisplayLink?
    private var shownGeneration = 0
    private var pending = false

    init(show: @escaping (CGImage) -> Void) {
        self.show = show
    }

    func bind(_ newSink: ComputerFrameSink) {
        guard sink !== newSink else { return }
        sink?.onFrame = nil
        sink = newSink
        shownGeneration = 0
        newSink.onFrame = { [weak self] in self?.request() }
        deliverLatest()
    }

    func detach() {
        link?.invalidate()
        link = nil
    }

    #if os(macOS)
    func attach(to view: NSView) {
        install(view.displayLink(target: self, selector: #selector(tick(_:))))
    }
    #else
    func attach() {
        install(CADisplayLink(target: self, selector: #selector(tick(_:))))
    }
    #endif

    private func install(_ newLink: CADisplayLink) {
        link?.invalidate()
        newLink.isPaused = !pending
        newLink.add(to: .main, forMode: .common)
        link = newLink
    }

    private func request() {
        pending = true
        link?.isPaused = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        link.isPaused = true
        guard pending else { return }
        pending = false
        deliverLatest()
    }

    private func deliverLatest() {
        guard let sink, sink.generation != shownGeneration, let image = sink.latest else { return }
        shownGeneration = sink.generation
        show(image)
        PalPerf.event("computer.frame.shown")
    }
}
