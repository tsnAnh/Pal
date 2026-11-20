import SwiftUI

#if os(macOS)
struct MacSheetRequest: Identifiable {
    let id: UUID
    let content: () -> AnyView
    let dismiss: () -> Void
    let onDismiss: (() -> Void)?
}

@MainActor
@Observable
final class MacSheetCenter {
    private(set) var stack: [MacSheetRequest] = []

    func present(_ request: MacSheetRequest) {
        if let index = stack.firstIndex(where: { $0.id == request.id }) {
            stack[index] = request
        } else {
            stack.append(request)
        }
    }

    func withdraw(_ id: UUID) {
        guard let index = stack.firstIndex(where: { $0.id == id }) else { return }
        let request = stack.remove(at: index)
        request.onDismiss?()
    }
}

private struct MacSheetCenterKey: EnvironmentKey {
    static let defaultValue: MacSheetCenter? = nil
}

extension EnvironmentValues {
    var macSheetCenter: MacSheetCenter? {
        get { self[MacSheetCenterKey.self] }
        set { self[MacSheetCenterKey.self] = newValue }
    }
}
#endif

private func macSheetPresence<Item>(of item: Binding<Item?>) -> Binding<Bool> {
    Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
}

extension View {
    func macSheet<Sheet: View>(
        isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Sheet
    ) -> some View {
        modifier(MacSheetPresentation(isPresented: isPresented, onDismiss: onDismiss, sheet: { isPresented.wrappedValue ? content() : nil }))
    }

    func macSheet<Item, Sheet: View>(
        item: Binding<Item?>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping (Item) -> Sheet
    ) -> some View {
        modifier(MacSheetPresentation(isPresented: macSheetPresence(of: item), onDismiss: onDismiss, sheet: { item.wrappedValue.map(content) }))
    }
}

private struct MacSheetPresentation<Sheet: View>: ViewModifier {
    let isPresented: Binding<Bool>
    let onDismiss: (() -> Void)?
    let sheet: () -> Sheet?

    #if os(macOS)
    @Environment(\.macSheetCenter) private var center
    @State private var token = UUID()
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        if let center {
            content
                .onChange(of: isPresented.wrappedValue, initial: true) { _, shows in
                    if shows {
                        let flag = isPresented
                        center.present(MacSheetRequest(
                            id: token,
                            content: built,
                            dismiss: { flag.wrappedValue = false },
                            onDismiss: onDismiss
                        ))
                    } else {
                        center.withdraw(token)
                    }
                }
                .onDisappear { center.withdraw(token) }
        } else {
            system(content)
        }
        #else
        system(content)
        #endif
    }

    private func built() -> AnyView {
        guard let view = sheet() else { return AnyView(EmptyView()) }
        return AnyView(view)
    }

    private func system(_ content: Content) -> some View {
        content.sheet(isPresented: isPresented, onDismiss: onDismiss) {
            built().macSheetFrame()
        }
    }
}
