#if os(macOS)
import AppKit
import PalSettings
import SwiftUI

enum MacRecorderEvent {
    case chord(KeyChord)
    case cancel
    case clear
}

struct MacShortcutRecorder: NSViewRepresentable {
    let onEvent: (MacRecorderEvent) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEvent: onEvent) }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEvent = onEvent
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        var onEvent: (MacRecorderEvent) -> Void
        private var monitor: Any?

        init(onEvent: @escaping (MacRecorderEvent) -> Void) { self.onEvent = onEvent }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handle(event) ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> Bool {
            if event.isARepeat { return true }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let bare = flags.intersection([.command, .option, .control, .shift]).isEmpty
            switch event.keyCode {
            case 53 where bare:
                onEvent(.cancel)
            case 51 where bare, 117 where bare:
                onEvent(.clear)
            default:
                if let chord = MacKeyTranslator.chord(keyCode: event.keyCode, event: event, flags: flags) {
                    onEvent(.chord(chord))
                }
            }
            return true
        }
    }
}

enum MacKeyTranslator {
    private static let named: [UInt16: String] = [
        126: "up", 125: "down", 123: "left", 124: "right", 36: "return", 76: "return", 48: "tab", 49: "space",
        115: "home", 119: "end", 116: "pageUp", 121: "pageDown",
    ]

    private static let functionKeys: [UInt16: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10,
        103: 11, 111: 12, 105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20,
    ]

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> ChordModifiers {
        var result: ChordModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }

    static func chord(keyCode: UInt16, event: NSEvent, flags: NSEvent.ModifierFlags) -> KeyChord? {
        let mods = modifiers(flags)
        if let key = named[keyCode] { return KeyChord(key: key, modifiers: mods) }
        if let number = functionKeys[keyCode] { return KeyChord(key: "f\(number)", modifiers: mods) }
        guard let raw = event.characters(byApplyingModifiers: []), raw.count == 1 else { return nil }
        return KeyChord(key: raw.lowercased(), modifiers: mods)
    }
}
#endif
