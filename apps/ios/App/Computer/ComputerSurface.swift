import HermesRFB
import SwiftUI
import UIKit

struct ComputerSurface: UIViewRepresentable {
    let image: CGImage?
    let remoteSize: RFBSize?
    let canControl: Bool
    let trackpad: Bool
    let keyboardShown: Bool
    let recenterToken: Int
    let model: ComputerModel

    func makeUIView(context: Context) -> ScreenSurfaceView {
        let view = ScreenSurfaceView()
        view.accessibilityIdentifier = "computerSurface"
        view.isAccessibilityElement = true
        view.accessibilityTraits = .image
        return view
    }

    func updateUIView(_ view: ScreenSurfaceView, context: Context) {
        view.model = model
        view.apply(image: image, remoteSize: remoteSize)
        view.canControl = canControl
        view.trackpad = trackpad && canControl
        view.recenter(token: recenterToken)
        view.setKeyboard(shown: keyboardShown && canControl)
    }
}

final class ScreenSurfaceView: UIView, UIKeyInput, UIGestureRecognizerDelegate {
    private static let scrollNotchPoints: CGFloat = 22
    private static let doubleTapDragDuration: TimeInterval = 0.25

    weak var model: ComputerModel?
    var canControl = false
    var trackpad = false {
        didSet { dragHoldRecognizer?.isEnabled = trackpad }
    }

    private var dragHoldRecognizer: UILongPressGestureRecognizer?
    private let imageLayer = CALayer()
    private let cursorLayer = CAShapeLayer()
    private var viewport = RFBViewport(container: .zero, remote: RFBSize(width: 1, height: 1))
    private var hasImage = false
    private var trackpadPoint: CGPoint?
    private var scrollRemainder: CGFloat = 0
    private var dragLastLocation: CGPoint?
    private var lastRecenterToken = 0
    private var wantsKeyboard = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        imageLayer.contentsGravity = .resize
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(imageLayer)
        cursorLayer.path = Self.cursorPath()
        cursorLayer.fillColor = UIColor.white.cgColor
        cursorLayer.strokeColor = UIColor.black.cgColor
        cursorLayer.lineWidth = 1
        cursorLayer.isHidden = true
        cursorLayer.actions = ["position": NSNull(), "hidden": NSNull()]
        layer.addSublayer(cursorLayer)
        installGestures()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func cursorPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: 0, y: 17))
        path.addLine(to: CGPoint(x: 4.5, y: 13))
        path.addLine(to: CGPoint(x: 8, y: 20))
        path.addLine(to: CGPoint(x: 11, y: 18.5))
        path.addLine(to: CGPoint(x: 7.5, y: 12))
        path.addLine(to: CGPoint(x: 13, y: 12))
        path.closeSubpath()
        return path
    }

    func apply(image: CGImage?, remoteSize: RFBSize?) {
        if let remoteSize, remoteSize != viewport.remote {
            viewport.update(container: bounds.size, remote: remoteSize)
            trackpadPoint = nil
        }
        if let image {
            imageLayer.contents = image
            hasImage = true
        }
        layoutViewport()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        viewport.update(container: bounds.size, remote: viewport.remote)
        layoutViewport()
    }

    private func layoutViewport() {
        imageLayer.isHidden = !hasImage
        imageLayer.frame = viewport.displayedFrame
        updateCursor()
    }

    private func updateCursor() {
        guard trackpad, hasImage else {
            cursorLayer.isHidden = true
            return
        }
        let remote = trackpadPoint ?? centreOfView()
        cursorLayer.position = viewport.viewPoint(forRemote: remote)
        cursorLayer.isHidden = false
    }

    private func centreOfView() -> CGPoint {
        viewport.remotePoint(forViewPoint: CGPoint(x: bounds.midX, y: bounds.midY), clampingToFrame: true)
            ?? CGPoint(x: CGFloat(viewport.remote.width) / 2, y: CGFloat(viewport.remote.height) / 2)
    }

    func recenter(token: Int) {
        guard token != lastRecenterToken else { return }
        lastRecenterToken = token
        trackpadPoint = centreOfView()
        model?.movePointerIndicator(to: trackpadPoint)
        updateCursor()
    }

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap))
        twoFingerTap.numberOfTouchesRequired = 2
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.maximumNumberOfTouches = 1
        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold))
        hold.minimumPressDuration = 0.5
        let dragHold = UILongPressGestureRecognizer(target: self, action: #selector(handleDragHold))
        dragHold.numberOfTapsRequired = 1
        dragHold.minimumPressDuration = Self.doubleTapDragDuration
        for recognizer in [tap, twoFingerTap, pan, twoFingerPan, pinch, hold, dragHold] as [UIGestureRecognizer] {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
        dragHold.isEnabled = trackpad
        dragHoldRecognizer = dragHold
        tap.require(toFail: dragHold)
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gesture is UIPinchGestureRecognizer && other is UIPanGestureRecognizer
            || gesture is UIPanGestureRecognizer && other is UIPinchGestureRecognizer
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        true
    }

    private func remote(at point: CGPoint) -> CGPoint? {
        viewport.remotePoint(forViewPoint: point)
    }

    private func pointerTarget(for viewPoint: CGPoint) -> CGPoint? {
        trackpad ? (trackpadPoint ?? centreOfView()) : remote(at: viewPoint)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard canControl, let target = pointerTarget(for: gesture.location(in: self)) else { return }
        model?.click(at: target)
    }

    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        guard canControl, let target = pointerTarget(for: centroid(of: gesture)) else { return }
        model?.click(at: target, button: RFBButtons.right)
    }

    @objc private func handleHold(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, canControl, let target = pointerTarget(for: gesture.location(in: self)) else { return }
        model?.click(at: target, button: RFBButtons.right)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        if viewport.isZoomed && !canControl {
            pan(viewportBy: gesture)
            return
        }
        guard canControl else { return }
        if trackpad {
            moveTrackpad(gesture)
        } else {
            drag(gesture)
        }
    }

    private func drag(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)
        guard let target = viewport.remotePoint(forViewPoint: location, clampingToFrame: true) else { return }
        switch gesture.state {
        case .began:
            let travelled = gesture.translation(in: self)
            let origin = CGPoint(x: location.x - travelled.x, y: location.y - travelled.y)
            let start = viewport.remotePoint(forViewPoint: origin, clampingToFrame: true) ?? target
            model?.pointer(start, buttons: 0)
            model?.pointer(start, buttons: RFBButtons.left)
            model?.pointer(target, buttons: RFBButtons.left)
        case .changed:
            model?.pointer(target, buttons: RFBButtons.left)
        case .ended, .cancelled, .failed:
            model?.pointer(target, buttons: 0)
        default:
            break
        }
    }

    private func moveTrackpad(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed || gesture.state == .began else { return }
        let delta = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        movePointer(by: delta)
    }

    private func movePointer(by delta: CGPoint) {
        let current = trackpadPoint ?? centreOfView()
        let scale = viewport.displayedFrame.width / CGFloat(viewport.remote.width)
        guard scale > 0 else { return }
        let next = CGPoint(
            x: min(max(current.x + delta.x / scale, 0), CGFloat(viewport.remote.width - 1)),
            y: min(max(current.y + delta.y / scale, 0), CGFloat(viewport.remote.height - 1))
        )
        trackpadPoint = next
        model?.movePointerIndicator(to: next)
        model?.pointer(next, buttons: model?.trackpadButtons ?? 0)
        updateCursor()
    }

    @objc private func handleDragHold(_ gesture: UILongPressGestureRecognizer) {
        guard trackpad, canControl else { return }
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            dragLastLocation = location
            model?.trackpadButtons = RFBButtons.left
            model?.pointer(trackpadPoint ?? centreOfView(), buttons: RFBButtons.left)
        case .changed:
            if let last = dragLastLocation {
                movePointer(by: CGPoint(x: location.x - last.x, y: location.y - last.y))
            }
            dragLastLocation = location
        case .ended, .cancelled, .failed:
            dragLastLocation = nil
            model?.trackpadButtons = 0
            model?.pointer(trackpadPoint ?? centreOfView(), buttons: 0)
        default:
            break
        }
    }

    @objc private func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
        if viewport.isZoomed || !canControl {
            pan(viewportBy: gesture)
            return
        }
        guard gesture.state == .changed, let target = pointerTarget(for: centroid(of: gesture)) else { return }
        scrollRemainder += gesture.translation(in: self).y
        gesture.setTranslation(.zero, in: self)
        let notches = Int(abs(scrollRemainder) / Self.scrollNotchPoints)
        guard notches > 0 else { return }
        let draggedUp = scrollRemainder < 0
        scrollRemainder -= CGFloat(notches) * Self.scrollNotchPoints * (draggedUp ? -1 : 1)
        model?.scroll(at: target, up: !draggedUp, notches: notches)
    }

    private func pan(viewportBy gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed else { return }
        viewport.pan(by: gesture.translation(in: self))
        gesture.setTranslation(.zero, in: self)
        layoutViewport()
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .changed else { return }
        viewport.pinch(by: gesture.scale, around: gesture.location(in: self))
        gesture.scale = 1
        layoutViewport()
    }

    private func centroid(of gesture: UIGestureRecognizer) -> CGPoint {
        let count = gesture.numberOfTouches
        guard count > 0 else { return gesture.location(in: self) }
        let points = (0..<count).map { gesture.location(ofTouch: $0, in: self) }
        return CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(count), y: points.map(\.y).reduce(0, +) / CGFloat(count))
    }

    func setKeyboard(shown: Bool) {
        guard shown != wantsKeyboard else { return }
        wantsKeyboard = shown
        if shown {
            becomeFirstResponder()
        } else {
            resignFirstResponder()
        }
    }

    override var canBecomeFirstResponder: Bool { true }

    var hasText: Bool { true }

    func insertText(_ text: String) {
        model?.type(text)
    }

    func deleteBackward() {
        model?.tap(key: RFBKeysym.backspace)
    }

    var autocorrectionType: UITextAutocorrectionType {
        get { .no }
        set {}
    }

    var autocapitalizationType: UITextAutocapitalizationType {
        get { .none }
        set {}
    }

    var spellCheckingType: UITextSpellCheckingType {
        get { .no }
        set {}
    }

    var smartQuotesType: UITextSmartQuotesType {
        get { .no }
        set {}
    }

    var smartDashesType: UITextSmartDashesType {
        get { .no }
        set {}
    }

    var smartInsertDeleteType: UITextSmartInsertDeleteType {
        get { .no }
        set {}
    }

    var keyboardType: UIKeyboardType {
        get { .asciiCapable }
        set {}
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        forward(presses, down: true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        forward(presses, down: false) { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        forward(presses, down: false) { super.pressesCancelled(presses, with: event) }
    }

    private func forward(_ presses: Set<UIPress>, down: Bool, fallback: () -> Void) {
        var unhandled = false
        for press in presses {
            guard let keysym = Self.specialKeys[press.key?.keyCode ?? .keyboardErrorUndefined] else {
                unhandled = true
                continue
            }
            model?.press(keysym, down: down)
        }
        if unhandled { fallback() }
    }

    private static let specialKeys: [UIKeyboardHIDUsage: UInt32] = [
        .keyboardEscape: RFBKeysym.escape,
        .keyboardTab: RFBKeysym.tab,
        .keyboardUpArrow: RFBKeysym.up,
        .keyboardDownArrow: RFBKeysym.down,
        .keyboardLeftArrow: RFBKeysym.left,
        .keyboardRightArrow: RFBKeysym.right,
        .keyboardDeleteForward: RFBKeysym.delete,
    ]
}
