import Observation
import SwiftUI

public enum MacDialogRole: Equatable, Sendable {
    case plain
    case destructive
    case cancel

    var buttonRole: ButtonRole? {
        switch self {
        case .plain: nil
        case .destructive: .destructive
        case .cancel: .cancel
        }
    }
}

public struct MacDialogAction: Identifiable {
    public let id = UUID()
    public let title: String
    public let role: MacDialogRole
    public let identifier: String?
    public let perform: @MainActor () -> Void

    public init(_ title: String, role: MacDialogRole = .plain, identifier: String? = nil, perform: @escaping @MainActor () -> Void = {}) {
        self.title = title
        self.role = role
        self.identifier = identifier
        self.perform = perform
    }
}

@MainActor
@Observable
public final class MacDialogCheckbox {
    public let title: String
    public let identifier: String
    public var isOn: Bool

    public init(_ title: String, identifier: String, isOn: Bool = false) {
        self.title = title
        self.identifier = identifier
        self.isOn = isOn
    }
}

public struct MacDialogContent {
    public let title: String
    public let message: String?
    public let checkbox: MacDialogCheckbox?
    public let actions: [MacDialogAction]

    public init(_ title: String, message: String? = nil, checkbox: MacDialogCheckbox? = nil, actions: [MacDialogAction]) {
        self.title = title
        self.message = message
        self.checkbox = checkbox
        self.actions = actions
    }

    public var cancelAction: MacDialogAction? { actions.first { $0.role == .cancel } }

    public var displayOrder: [MacDialogAction] {
        actions.filter { $0.role == .cancel } + actions.filter { $0.role != .cancel }
    }

    public var defaultAction: MacDialogAction? {
        actions.first { $0.role == .plain } ?? cancelAction
    }
}

public enum MacDialogKey: Equatable, Sendable {
    case returnKey
    case escape
}

public struct MacDialogRequest: Identifiable {
    public let id: UUID
    public let content: MacDialogContent
    let dismiss: @MainActor () -> Void

    public init(id: UUID, content: MacDialogContent, dismiss: @escaping @MainActor () -> Void) {
        self.id = id
        self.content = content
        self.dismiss = dismiss
    }

    @MainActor
    public func activate(_ action: MacDialogAction) {
        action.perform()
        dismiss()
    }

    @MainActor
    public func press(_ key: MacDialogKey) {
        switch key {
        case .returnKey: content.defaultAction.map(activate) ?? dismiss()
        case .escape: content.cancelAction.map(activate) ?? dismiss()
        }
    }
}

@MainActor
@Observable
public final class MacDialogCenter {
    public private(set) var queue: [MacDialogRequest] = []

    public init() {}

    public var current: MacDialogRequest? { queue.first }

    public func present(_ request: MacDialogRequest) {
        if let index = queue.firstIndex(where: { $0.id == request.id }) {
            queue[index] = request
        } else {
            queue.append(request)
        }
    }

    public func withdraw(_ id: UUID) {
        guard queue.contains(where: { $0.id == id }) else { return }
        queue.removeAll { $0.id == id }
    }
}

private struct MacDialogCenterKey: EnvironmentKey {
    static let defaultValue: MacDialogCenter? = nil
}

private struct MacWindowSizeKey: EnvironmentKey {
    static let defaultValue: MacWindowSize? = nil
}

@MainActor
@Observable
public final class MacWindowSize {
    public private(set) var size = CGSize.zero

    public init() {}

    public func update(_ next: CGSize) {
        if next != size { size = next }
    }
}

public extension EnvironmentValues {
    var macDialogCenter: MacDialogCenter? {
        get { self[MacDialogCenterKey.self] }
        set { self[MacDialogCenterKey.self] = newValue }
    }

    var macWindowSize: MacWindowSize? {
        get { self[MacWindowSizeKey.self] }
        set { self[MacWindowSizeKey.self] = newValue }
    }
}

public extension View {
    func macAlert(isPresented: Binding<Bool>, _ content: @escaping () -> MacDialogContent) -> some View {
        modifier(MacDialogPresentation(kind: .alert, isPresented: isPresented, content: { isPresented.wrappedValue ? content() : nil }))
    }

    func macAlert<Item>(item: Binding<Item?>, _ content: @escaping (Item) -> MacDialogContent) -> some View {
        modifier(MacDialogPresentation(kind: .alert, isPresented: macPresence(of: item), content: { item.wrappedValue.map(content) }))
    }

    func macConfirm(isPresented: Binding<Bool>, _ content: @escaping () -> MacDialogContent) -> some View {
        modifier(MacDialogPresentation(kind: .confirm, isPresented: isPresented, content: { isPresented.wrappedValue ? content() : nil }))
    }

    func macConfirm<Item>(item: Binding<Item?>, _ content: @escaping (Item) -> MacDialogContent) -> some View {
        modifier(MacDialogPresentation(kind: .confirm, isPresented: macPresence(of: item), content: { item.wrappedValue.map(content) }))
    }
}

private func macPresence<Item>(of item: Binding<Item?>) -> Binding<Bool> {
    Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
}

enum MacDialogKind { case alert, confirm }

private struct MacDialogPresentation: ViewModifier {
    let kind: MacDialogKind
    let isPresented: Binding<Bool>
    let content: () -> MacDialogContent?

    #if os(macOS)
    @Environment(\.macDialogCenter) private var center
    @State private var token = UUID()
    #endif

    func body(content view: Content) -> some View {
        #if os(macOS)
        if let center {
            view
                .onChange(of: isPresented.wrappedValue, initial: true) { _, shows in
                    if shows, let dialog = content() {
                        let flag = isPresented
                        center.present(MacDialogRequest(id: token, content: dialog, dismiss: { flag.wrappedValue = false }))
                    } else {
                        center.withdraw(token)
                    }
                }
                .onDisappear { center.withdraw(token) }
        } else {
            system(view)
        }
        #else
        system(view)
        #endif
    }

    @ViewBuilder
    private func system(_ view: Content) -> some View {
        let dialog = content()
        switch kind {
        case .alert:
            view.alert(dialog?.title ?? "", isPresented: isPresented) {
                systemButtons(dialog)
            } message: {
                if let message = dialog?.message { Text(message) }
            }
        case .confirm:
            view.confirmationDialog(dialog?.title ?? "", isPresented: isPresented, titleVisibility: .visible) {
                systemButtons(dialog)
            } message: {
                if let message = dialog?.message { Text(message) }
            }
        }
    }

    @ViewBuilder
    private func systemButtons(_ dialog: MacDialogContent?) -> some View {
        ForEach(dialog?.actions ?? []) { action in
            Button(action.title, role: action.role.buttonRole) { action.perform() }
                .accessibilityIdentifier(action.identifier ?? action.title)
        }
    }
}
