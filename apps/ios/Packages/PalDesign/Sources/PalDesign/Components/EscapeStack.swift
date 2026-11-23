import Observation
import SwiftUI

@MainActor
@Observable
public final class MacEscapeStack {
    struct Entry {
        let id: UUID
        var layer: EscapeLayer
        var nested: Bool
        var policy: EscapePolicy
        var dismiss: @MainActor () -> Void
        let serial: Int
    }

    public let dialogs: MacDialogCenter

    private var entries: [Entry] = []
    @ObservationIgnored private var serial = 0

    public init(dialogs: MacDialogCenter = MacDialogCenter()) {
        self.dialogs = dialogs
    }

    public var hasEntries: Bool { !entries.isEmpty }

    var top: Entry? {
        entries.max { ($0.layer, $0.nested ? 1 : 0, $0.serial) < ($1.layer, $1.nested ? 1 : 0, $1.serial) }
    }

    public func register(_ id: UUID, layer: EscapeLayer, nested: Bool = false, policy: EscapePolicy, dismiss: @escaping @MainActor () -> Void) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].layer = layer
            entries[index].nested = nested
            entries[index].policy = policy
            entries[index].dismiss = dismiss
        } else {
            serial += 1
            entries.append(Entry(id: id, layer: layer, nested: nested, policy: policy, dismiss: dismiss, serial: serial))
        }
    }

    public func unregister(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    @discardableResult
    public func press() -> EscapeOutcome {
        guard let top else { return .ignore }
        let outcome = top.policy.outcome
        switch outcome {
        case .dismiss: top.dismiss()
        case .confirmDiscard: confirmDiscard(top)
        case .ignore: break
        }
        return outcome
    }

    private func confirmDiscard(_ entry: Entry) {
        let id = UUID()
        dialogs.present(MacDialogRequest(id: id, content: Self.discardContent(discard: entry.dismiss)) { [dialogs] in
            dialogs.withdraw(id)
        })
    }

    static func discardContent(discard: @escaping @MainActor () -> Void) -> MacDialogContent {
        MacDialogContent(
            String(localized: "Discard changes?"),
            actions: [
                MacDialogAction(String(localized: "Keep editing"), role: .cancel, identifier: "escapeKeepEditing"),
                MacDialogAction(String(localized: "Discard"), role: .destructive, identifier: "escapeDiscard", perform: discard),
            ]
        )
    }
}

public extension EnvironmentValues {
    @Entry var macEscapeStack: MacEscapeStack?
}

public extension View {
    func palEscape(_ layer: EscapeLayer, nested: Bool = false, policy: EscapePolicy = .dismisses, dismiss: @escaping () -> Void) -> some View {
        modifier(PalEscapeModifier(layer: layer, nested: nested, policy: policy, dismiss: dismiss))
    }

    func palEscapePolicy(_ policy: EscapePolicy) -> some View {
        interactiveDismissDisabled(!policy.allowsClose)
            .preference(key: EscapePolicyKey.self, value: policy)
    }

    func palEscapeRoot(_ stack: MacEscapeStack) -> some View {
        modifier(PalEscapeRoot(stack: stack))
    }

    func palCancelShortcut() -> some View {
        modifier(PalCancelShortcut())
    }
}

private struct PalEscapeRoot: ViewModifier {
    let stack: MacEscapeStack

    func body(content: Content) -> some View {
        content
            .environment(\.macEscapeStack, stack)
            .background {
                Button("") { stack.press() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(!stack.hasEntries)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
    }
}

private struct PalEscapeModifier: ViewModifier {
    let layer: EscapeLayer
    let nested: Bool
    let policy: EscapePolicy
    let dismiss: () -> Void

    @Environment(\.macEscapeStack) private var stack
    @State private var id = UUID()

    func body(content: Content) -> some View {
        if layer != .native, let stack {
            content
                .onAppear { register(in: stack) }
                .onChange(of: policy) { register(in: stack) }
                .onDisappear { stack.unregister(id) }
        } else {
            content
                .environment(\.escapeHostLayer, nil)
                .background {
                    if policy == .dismisses {
                        Button("") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                            .frame(width: 0, height: 0)
                            .opacity(0)
                            .accessibilityHidden(true)
                    }
                }
                .interactiveDismissDisabled(!policy.allowsClose)
        }
    }

    private func register(in stack: MacEscapeStack) {
        stack.register(id, layer: layer, nested: nested, policy: policy) { dismiss() }
    }
}

private struct PalCancelShortcut: ViewModifier {
    @Environment(\.escapeHostLayer) private var hostLayer

    func body(content: Content) -> some View {
        if hostLayer != nil {
            content
        } else {
            content.keyboardShortcut(.cancelAction)
        }
    }
}
