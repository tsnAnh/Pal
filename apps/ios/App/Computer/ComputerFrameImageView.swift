#if os(macOS)
import AppKit

final class FrameImageView: NSView {
    private lazy var delivery = ComputerFrameDelivery { [weak self] image in self?.show(image) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        delivery.detach()
        if window != nil { delivery.attach(to: self) }
    }

    func bind(_ sink: ComputerFrameSink) {
        delivery.bind(sink)
    }

    private func show(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }
}
#endif

#if os(iOS)
import UIKit

final class FrameImageView: UIView {
    var onFirstImage: (() -> Void)?
    private lazy var delivery = ComputerFrameDelivery { [weak self] image in self?.show(image) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        layer.contentsGravity = .resize
        layer.magnificationFilter = .linear
        layer.minificationFilter = .trilinear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        delivery.detach()
        if window != nil { delivery.attach() }
    }

    func bind(_ sink: ComputerFrameSink) {
        delivery.bind(sink)
    }

    private func show(_ image: CGImage) {
        layer.contents = image
        guard isHidden else { return }
        isHidden = false
        onFirstImage?()
    }
}
#endif
