import PalDesign
import SwiftUI

#if os(macOS)
struct MacSheetRequest: Identifiable {
    let id: UUID
    let content: () -> AnyView
    let dismiss: () -> Void
    let onDismiss: (() -> Void)?
    let size: MacModalSize
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

extension EnvironmentValues {
    @Entry var sheetClose: (() -> Void)?
}

struct SheetDismiss: DynamicProperty {
    @Environment(\.sheetClose) private var layerClose
    @Environment(\.dismiss) private var systemDismiss

    func callAsFunction() {
        if let layerClose { layerClose() } else { systemDismiss() }
    }
}

struct MacSheetDismissLockKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

private func macSheetPresence<Item>(of item: Binding<Item?>) -> Binding<Bool> {
    Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
}

extension View {
    func macSheet<Sheet: View>(
        isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, size: MacModalSize, @ViewBuilder content: @escaping () -> Sheet
    ) -> some View {
        modifier(MacSheetPresentation(
            isPresented: isPresented, size: size, onDismiss: onDismiss, sheet: { content() }
        ))
    }

    func macSheet<Item, Sheet: View>(
        item: Binding<Item?>, onDismiss: (() -> Void)? = nil, size: MacModalSize, @ViewBuilder content: @escaping (Item) -> Sheet
    ) -> some View {
        modifier(MacSheetPresentation(
            isPresented: macSheetPresence(of: item), size: size, onDismiss: onDismiss, sheet: { item.wrappedValue.map(content) }
        ))
    }

    func macSheetDismissDisabled(_ disabled: Bool) -> some View {
        interactiveDismissDisabled(disabled)
            .preference(key: MacSheetDismissLockKey.self, value: disabled)
    }
}

private struct MacSheetPresentation<Sheet: View>: ViewModifier {
    let isPresented: Binding<Bool>
    let size: MacModalSize
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
                            content: { isPresented.wrappedValue ? built() : AnyView(EmptyView()) },
                            dismiss: { flag.wrappedValue = false },
                            onDismiss: onDismiss,
                            size: size
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
            built()
                .environment(\.sheetClose, nil)
                .environment(\.sheetChromeHostedInNavigation, false)
                .macSheetFrame(size: size)
        }
    }
}

extension View {
    func macModalFullHeight(_ size: MacModalSize) -> some View {
        #if os(macOS)
        modifier(MacModalFullHeight(size: size))
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct MacModalFullHeight: ViewModifier {
    let size: MacModalSize

    @Environment(\.macWindowSize) private var windowSize

    func body(content: Content) -> some View {
        content.frame(idealHeight: size.frame(in: windowSize?.size ?? .zero).maxHeight)
    }
}
#endif
