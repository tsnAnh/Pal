import PalChat
import SwiftUI

#if os(iOS)
import UIKit

final class PadKeyCatcherView: UIView {
    var isBlocked: () -> Bool = { false }
    var typed: (String) -> Void = { _ in }

    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var passedOn = presses
        let blocked = isBlocked() || window?.rootViewController?.presentedViewController != nil
        for press in presses {
            guard let key = press.key,
                  let text = TypeToFocus.insertion(
                      characters: key.characters, modifiers: Self.modifiers(of: key.modifierFlags), textInputFocused: false, blocked: blocked
                  )
            else { continue }
            typed(text)
            passedOn.remove(press)
        }
        if !passedOn.isEmpty { super.pressesBegan(passedOn, with: event) }
    }

    func claimKeys() {
        guard window != nil, !isFirstResponder, UIResponder.currentFirstResponder() == nil else { return }
        becomeFirstResponder()
    }

    func releaseKeys() {
        if isFirstResponder { resignFirstResponder() }
    }

    private static func modifiers(of flags: UIKeyModifierFlags) -> TypeToFocus.Modifiers {
        var result: TypeToFocus.Modifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.alternate) { result.insert(.option) }
        return result
    }
}

private extension UIResponder {
    private static weak var found: UIResponder?

    static func currentFirstResponder() -> UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(noteFirstResponder), to: nil, from: nil, for: nil)
        return found
    }

    @objc private func noteFirstResponder() {
        Self.found = self
    }
}

private struct PadKeyCatcher: UIViewRepresentable {
    let active: Bool
    let blocked: () -> Bool
    let typed: (String) -> Void

    func makeUIView(context: Context) -> PadKeyCatcherView {
        let view = PadKeyCatcherView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: PadKeyCatcherView, context: Context) {
        view.isBlocked = blocked
        view.typed = typed
        if active {
            DispatchQueue.main.async { view.claimKeys() }
        } else {
            view.releaseKeys()
        }
    }
}

private struct PadTypeToFocusComposer: ViewModifier {
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    let blocked: () -> Bool

    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            let suspended = blocked()
            content.background(
                PadKeyCatcher(active: !focused.wrappedValue && !suspended, blocked: blocked) { text in
                    draft += text
                    focused.wrappedValue = true
                }
            )
        } else {
            content
        }
    }
}

extension View {
    func typeToFocusComposer(draft: Binding<String>, focused: FocusState<Bool>.Binding, blocked: @escaping () -> Bool) -> some View {
        modifier(PadTypeToFocusComposer(draft: draft, focused: focused, blocked: blocked))
    }
}
#endif
