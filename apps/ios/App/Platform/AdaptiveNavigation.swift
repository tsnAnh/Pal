import PalDesign
import SwiftUI

#if os(iOS)
import UIKit

@MainActor
enum ShellLayout {
    static func usesSplit(_ sizeClass: UserInterfaceSizeClass?) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular
    }
}

private struct SplitNavigationKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var usesSplitNavigation: Bool {
        get { self[SplitNavigationKey.self] }
        set { self[SplitNavigationKey.self] = newValue }
    }
}

struct AdaptiveNavigation<Route: Hashable, Sidebar: View, Destination: View, Placeholder: View>: View {
    @Binding var path: [Route]
    let sidebar: Sidebar
    let destination: (Route) -> Destination
    let placeholder: Placeholder

    @Environment(\.horizontalSizeClass) private var sizeClass

    init(
        path: Binding<[Route]>,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder destination: @escaping (Route) -> Destination,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        _path = path
        self.sidebar = sidebar()
        self.destination = destination
        self.placeholder = placeholder()
    }

    var body: some View {
        if ShellLayout.usesSplit(sizeClass) {
            split
        } else {
            NavigationStack(path: $path) {
                sidebar.navigationDestination(for: Route.self, destination: destination)
            }
        }
    }

    private var split: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack(path: detailPath) {
                Group {
                    if let first = path.first {
                        destination(first).id(first)
                    } else {
                        placeholder
                    }
                }
                .navigationDestination(for: Route.self) { route in
                    destination(route)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.usesSplitNavigation, true)
    }

    private var detailPath: Binding<[Route]> {
        Binding(
            get: { Array(path.dropFirst()) },
            set: { path = Array(path.prefix(1)) + $0 }
        )
    }
}
#endif

struct RouteLink<Route: Hashable, Label: View>: View {
    let value: Route
    let isSelected: Bool
    let select: () -> Void
    @ViewBuilder let label: Label

    #if os(iOS)
    @Environment(\.usesSplitNavigation) private var usesSplit

    var body: some View {
        if usesSplit {
            Button(action: select) { label }
                .background(isSelected ? PalTokens.selected : .clear, in: .rect(cornerRadius: 10))
        } else {
            NavigationLink(value: value) { label }
        }
    }
    #elseif os(macOS)
    var body: some View {
        Button(action: select) { label }
            .background(isSelected ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 10))
    }
    #endif
}

extension ToolbarItemPlacement {
    static var leadingBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    static var trailingBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}

extension View {
    func macWindowSizing() -> some View {
        #if os(macOS)
        frame(minWidth: 760, minHeight: 520)
        #else
        self
        #endif
    }
}

extension View {
    func fullCover<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented) {
            content().frame(minWidth: 560, idealWidth: 640, minHeight: 520, idealHeight: 680)
        }
        #endif
    }
}

extension View {
    func macSheetFrame() -> some View {
        #if os(macOS)
        frame(minWidth: 480, idealWidth: 560, minHeight: 520, idealHeight: 680)
        #else
        self
        #endif
    }
}
