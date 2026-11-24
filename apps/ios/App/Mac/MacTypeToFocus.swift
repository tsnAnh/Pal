import PalChat
import SwiftUI

#if os(macOS)
import AppKit

@MainActor
final class MacTypeToFocusMonitor {
    weak var window: NSWindow?
    var isBlocked: () -> Bool = { false }
    var focusComposer: () -> Void = {}
    var insertFallback: (String) -> Void = { _ in }
    private var monitor: Any?
    private static let focusAttempts = 10

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
        guard let text = TypeToFocus.insertion(
            characters: event.characters ?? "", modifiers: Self.modifiers(of: event),
            textInputFocused: window.firstResponder is NSText, blocked: isBlocked()
        ) else { return false }
        focusComposer()
        Task { await forward(event, orInsert: text) }
        return true
    }

    private func forward(_ event: NSEvent, orInsert text: String) async {
        for _ in 0..<Self.focusAttempts {
            try? await Task.sleep(for: .milliseconds(10))
            if let editor = window?.firstResponder as? NSTextView, editor.isEditable {
                editor.keyDown(with: event)
                return
            }
        }
        insertFallback(text)
    }

    static func modifiers(of event: NSEvent) -> TypeToFocus.Modifiers {
        var result: TypeToFocus.Modifiers = []
        if event.modifierFlags.contains(.command) { result.insert(.command) }
        if event.modifierFlags.contains(.control) { result.insert(.control) }
        if event.modifierFlags.contains(.option) { result.insert(.option) }
        return result
    }
}

private struct MacWindowAnchor: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { Anchor(found: found) }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class Anchor: NSView {
        let found: (NSWindow?) -> Void

        init(found: @escaping (NSWindow?) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() { found(window) }
    }
}

private struct TypeToFocusComposer: ViewModifier {
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    let blocked: () -> Bool
    @State private var monitor = MacTypeToFocusMonitor()

    func body(content: Content) -> some View {
        content
            .background(MacWindowAnchor { monitor.window = $0 })
            .onAppear {
                monitor.isBlocked = blocked
                monitor.focusComposer = { focused.wrappedValue = true }
                monitor.insertFallback = { draft += $0 }
                monitor.start()
            }
            .onDisappear { monitor.stop() }
    }
}

extension View {
    func typeToFocusComposer(draft: Binding<String>, focused: FocusState<Bool>.Binding, blocked: @escaping () -> Bool) -> some View {
        modifier(TypeToFocusComposer(draft: draft, focused: focused, blocked: blocked))
    }
}
#else
extension View {
    func typeToFocusComposer(draft: Binding<String>, focused: FocusState<Bool>.Binding, blocked: @escaping () -> Bool) -> some View {
        self
    }
}
#endif
