#if os(macOS)
import AppKit
import HermesRFB
import SwiftUI

struct ComputerSurface: NSViewRepresentable {
    let image: CGImage?
    let remoteSize: RFBSize?
    let canControl: Bool
    let trackpad: Bool
    let keyboardShown: Bool
    let recenterToken: Int
    let model: ComputerModel

    func makeNSView(context: Context) -> ScreenSurfaceView {
        let view = ScreenSurfaceView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityIdentifier("computerSurface")
        view.setAccessibilityLabel(String(localized: "Computer screen"))
        return view
    }

    func updateNSView(_ view: ScreenSurfaceView, context: Context) {
        view.model = model
        view.apply(image: image, remoteSize: remoteSize)
        view.canControl = canControl
    }
}

final class ScreenSurfaceView: NSView {
    private static let scrollNotchPoints: CGFloat = 22
    private static let zoomPointsPerDoubling: CGFloat = 120

    weak var model: ComputerModel?
    var canControl = false {
        didSet {
            guard canControl != oldValue else { return }
            if canControl {
                window?.makeFirstResponder(self)
            } else {
                releaseEverything()
            }
        }
    }

    private var image: CGImage?
    private var viewport = RFBViewport(container: .zero, remote: RFBSize(width: 1, height: 1))
    private var buttonMask: UInt8 = 0
    private var lastSentPoint: CGPoint?
    private var scrollRemainder: CGFloat = 0
    private var heldKeys: [UInt16: UInt32] = [:]
    private var heldModifiers: [UInt: UInt32] = [:]
    private var markedText = NSMutableAttributedString()
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(image newImage: CGImage?, remoteSize: RFBSize?) {
        if let remoteSize, remoteSize != viewport.remote {
            viewport.update(container: bounds.size, remote: remoteSize)
        }
        if let newImage { image = newImage }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        viewport.update(container: bounds.size, remote: viewport.remote)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if canControl { window?.makeFirstResponder(self) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let frame = viewport.displayedFrame
        context.saveGState()
        context.interpolationQuality = .high
        context.translateBy(x: frame.minX, y: frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        context.restoreGState()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func viewPoint(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func send(_ point: CGPoint) {
        model?.pointer(point, buttons: buttonMask)
        lastSentPoint = point
    }

    private func press(_ button: UInt8, at event: NSEvent) {
        window?.makeFirstResponder(self)
        guard canControl, let target = viewport.remotePoint(forViewPoint: viewPoint(of: event)) else { return }
        buttonMask |= button
        send(target)
    }

    private func drag(_ button: UInt8, with event: NSEvent) {
        guard buttonMask & button != 0 else {
            if viewport.isZoomed, !canControl { panViewport(by: CGPoint(x: event.deltaX, y: event.deltaY)) }
            return
        }
        guard let target = viewport.remotePoint(forViewPoint: viewPoint(of: event), clampingToFrame: true) else { return }
        send(target)
    }

    private func release(_ button: UInt8, with event: NSEvent) {
        guard buttonMask & button != 0 else { return }
        buttonMask &= ~button
        let target = viewport.remotePoint(forViewPoint: viewPoint(of: event), clampingToFrame: true) ?? lastSentPoint
        if let target { send(target) }
    }

    override func mouseDown(with event: NSEvent) {
        if !canControl {
            window?.makeFirstResponder(self)
            return
        }
        press(RFBButtons.left, at: event)
    }

    override func mouseDragged(with event: NSEvent) { drag(RFBButtons.left, with: event) }
    override func mouseUp(with event: NSEvent) { release(RFBButtons.left, with: event) }
    override func rightMouseDown(with event: NSEvent) { press(RFBButtons.right, at: event) }
    override func rightMouseDragged(with event: NSEvent) { drag(RFBButtons.right, with: event) }
    override func rightMouseUp(with event: NSEvent) { release(RFBButtons.right, with: event) }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        press(RFBButtons.middle, at: event)
    }

    override func otherMouseDragged(with event: NSEvent) { drag(RFBButtons.middle, with: event) }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        release(RFBButtons.middle, with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        guard canControl, buttonMask == 0,
              let target = viewport.remotePoint(forViewPoint: viewPoint(of: event)),
              target.x.rounded() != lastSentPoint?.x.rounded() || target.y.rounded() != lastSentPoint?.y.rounded()
        else { return }
        send(target)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * Self.scrollNotchPoints
        if event.modifierFlags.contains(.option) {
            zoom(byPoints: delta, around: viewPoint(of: event))
            return
        }
        if viewport.isZoomed || !canControl {
            panViewport(by: CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY))
            return
        }
        guard let target = viewport.remotePoint(forViewPoint: viewPoint(of: event), clampingToFrame: true) else { return }
        scrollRemainder += delta
        let notches = Int(abs(scrollRemainder) / Self.scrollNotchPoints)
        guard notches > 0 else { return }
        let up = scrollRemainder > 0
        scrollRemainder -= CGFloat(notches) * Self.scrollNotchPoints * (up ? 1 : -1)
        model?.scroll(at: target, up: up, notches: notches)
    }

    override func magnify(with event: NSEvent) {
        viewport.pinch(by: 1 + event.magnification, around: viewPoint(of: event))
        needsDisplay = true
    }

    private func zoom(byPoints points: CGFloat, around focal: CGPoint) {
        viewport.pinch(by: pow(2, points / Self.zoomPointsPerDoubling), around: focal)
        needsDisplay = true
    }

    private func panViewport(by delta: CGPoint) {
        viewport.pan(by: delta)
        needsDisplay = true
    }

    private static let specialKeys: [UInt16: UInt32] = [
        36: RFBKeysym.returnKey,
        76: 0xFF8D,
        48: RFBKeysym.tab,
        51: RFBKeysym.backspace,
        53: RFBKeysym.escape,
        117: RFBKeysym.delete,
        115: 0xFF50,
        119: 0xFF57,
        116: 0xFF55,
        121: 0xFF56,
        123: RFBKeysym.left,
        124: RFBKeysym.right,
        125: RFBKeysym.down,
        126: RFBKeysym.up,
        122: 0xFFBE, 120: 0xFFBF, 99: 0xFFC0, 118: 0xFFC1, 96: 0xFFC2, 97: 0xFFC3,
        98: 0xFFC4, 100: 0xFFC5, 101: 0xFFC6, 109: 0xFFC7, 103: 0xFFC8, 111: 0xFFC9,
    ]

    private static let modifierKeys: [(NSEvent.ModifierFlags, UInt32)] = [
        (.shift, 0xFFE1),
        (.control, 0xFFE4),
        (.option, 0xFFE9),
        (.command, 0xFFE3),
    ]

    private static let appOwnedCommandKeys: Set<String> = ["q", "w", "h", "m", ",", "`"]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard canControl, window?.firstResponder === self, event.modifierFlags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased(), !Self.appOwnedCommandKeys.contains(key)
        else { return false }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard canControl else {
            super.keyDown(with: event)
            return
        }
        if hasMarkedText() {
            _ = inputContext?.handleEvent(event)
            return
        }
        let chord = !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if let keysym = Self.specialKeys[event.keyCode] {
            hold(event.keyCode, keysym)
        } else if chord, let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first {
            hold(event.keyCode, RFBKeysym.forScalar(scalar))
        } else if inputContext?.handleEvent(event) != true, let text = event.characters, !text.isEmpty {
            model?.type(text)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let keysym = heldKeys.removeValue(forKey: event.keyCode) else { return }
        model?.press(keysym, down: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard canControl else { return }
        for (flag, keysym) in Self.modifierKeys {
            let isDown = event.modifierFlags.contains(flag)
            let wasDown = heldModifiers[flag.rawValue] != nil
            guard isDown != wasDown else { continue }
            if isDown {
                heldModifiers[flag.rawValue] = keysym
            } else {
                heldModifiers[flag.rawValue] = nil
            }
            model?.press(keysym, down: isDown)
        }
    }

    private func hold(_ keyCode: UInt16, _ keysym: UInt32) {
        if heldKeys[keyCode] != nil { model?.press(keysym, down: false) }
        heldKeys[keyCode] = keysym
        model?.press(keysym, down: true)
    }

    override func resignFirstResponder() -> Bool {
        releaseEverything()
        return super.resignFirstResponder()
    }

    private func releaseEverything() {
        for keysym in heldKeys.values { model?.press(keysym, down: false) }
        heldKeys.removeAll()
        for keysym in heldModifiers.values { model?.press(keysym, down: false) }
        heldModifiers.removeAll()
        if buttonMask != 0, let point = lastSentPoint {
            buttonMask = 0
            model?.pointer(point, buttons: 0)
        }
        markedText = NSMutableAttributedString()
        inputContext?.discardMarkedText()
    }

    override func doCommand(by selector: Selector) {}
}

extension ScreenSurfaceView: @MainActor NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        markedText = NSMutableAttributedString()
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        guard !text.isEmpty else { return }
        model?.type(text)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let attributed = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: attributed)
        } else if let plain = string as? String {
            markedText = NSMutableAttributedString(string: plain)
        }
    }

    func unmarkText() { markedText = NSMutableAttributedString() }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { markedText.length == 0 ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.length) }
    func hasMarkedText() -> Bool { markedText.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        let anchor = NSRect(x: bounds.midX, y: bounds.maxY - 24, width: 1, height: 20)
        return window.convertToScreen(convert(anchor, to: nil))
    }
}
#endif
