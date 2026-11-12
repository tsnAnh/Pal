import Foundation
import PalProtocol
import Synchronization
#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
#endif

enum AccessibilityAccess {
    private static let asked = Mutex(false)

    static var status: DeviceOSPermission {
        #if os(macOS)
        if AXIsProcessTrusted() { return .granted }
        return asked.withLock { $0 } ? .denied : .notDetermined
        #else
        .unsupported
        #endif
    }

    static func request() {
        #if os(macOS)
        asked.withLock { $0 = true }
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        #endif
    }
}

#if os(macOS)
public struct CGEventInputSource: InputEventSource {
    public static let eventTag: Int64 = 0x5041_4C49

    public init() {}

    public var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    public var isScreenLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = session?["CGSSessionScreenIsLocked"] as? Bool == true
        let away = session?["kCGSSessionOnConsoleKey"] as? Bool == false
        let saver = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.ScreenSaver.Engine").isEmpty
        return locked || away || saver
    }

    public var isSecureInputActive: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["kCGSSessionSecureInputPID"] != nil
    }

    public var isOwnAppFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    public func displays() -> [InputDisplayRecord] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let main = CGMainDisplayID()
        let ordered = ids.prefix(Int(count)).sorted { left, right in
            if (left == main) != (right == main) { return left == main }
            return left < right
        }
        return ordered.enumerated().map { index, id in
            let bounds = CGDisplayBounds(id)
            let pixels = CGDisplayCopyDisplayMode(id).map { Double($0.pixelWidth) } ?? bounds.width
            return InputDisplayRecord(
                id: index + 1, isMain: CGDisplayIsMain(id) != 0, x: bounds.origin.x, y: bounds.origin.y,
                width: bounds.width, height: bounds.height, scale: bounds.width > 0 ? pixels / bounds.width : 1
            )
        }
    }

    public func pointer() -> (x: Double, y: Double) {
        let location = CGEvent(source: nil)?.location ?? .zero
        return (location.x, location.y)
    }

    public func isOwnWindow(atX x: Double, y: Double) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return false }
        let mine = Int(ProcessInfo.processInfo.processIdentifier)
        let point = CGPoint(x: x, y: y)
        for window in windows {
            guard (window[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.contains(point)
            else { continue }
            return window[kCGWindowOwnerPID as String] as? Int == mine
        }
        return false
    }

    public func post(_ event: InputEvent) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState), let cgEvent = Self.make(event, source: source) else { return false }
        cgEvent.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        cgEvent.post(tap: .cghidEventTap)
        return true
    }

    private static func make(_ event: InputEvent, source: CGEventSource) -> CGEvent? {
        switch event {
        case .mouseMove(let x, let y):
            return CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)
        case .mouseDown(let x, let y, let button, let state):
            return mouse(source, down: true, x: x, y: y, button: button, clickState: state)
        case .mouseUp(let x, let y, let button, let state):
            return mouse(source, down: false, x: x, y: y, button: button, clickState: state)
        case .mouseDrag(let x, let y, let button):
            let type: CGEventType = switch button {
            case .left: .leftMouseDragged
            case .right: .rightMouseDragged
            case .middle: .otherMouseDragged
            }
            return CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: cgButton(button))
        case .scroll(let dx, let dy):
            return CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)
        case .key(let code, let down, let modifiers):
            let key = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
            key?.flags = flags(modifiers)
            return key
        case .character(let text, let down):
            let key = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
            let units = Array(text.utf16)
            key?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            return key
        }
    }

    private static func mouse(_ source: CGEventSource, down: Bool, x: Double, y: Double, button: InputButton, clickState: Int) -> CGEvent? {
        let type: CGEventType = switch (button, down) {
        case (.left, true): .leftMouseDown
        case (.left, false): .leftMouseUp
        case (.right, true): .rightMouseDown
        case (.right, false): .rightMouseUp
        case (.middle, true): .otherMouseDown
        case (.middle, false): .otherMouseUp
        }
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: cgButton(button))
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        return event
    }

    private static func cgButton(_ button: InputButton) -> CGMouseButton {
        switch button {
        case .left: .left
        case .right: .right
        case .middle: .center
        }
    }

    private static func flags(_ modifiers: InputModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        return flags
    }
}

extension InputController {
    public static let shared = InputController(source: CGEventInputSource())
}
#endif
