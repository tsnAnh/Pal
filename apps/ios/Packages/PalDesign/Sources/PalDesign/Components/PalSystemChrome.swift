import SwiftUI

public struct PalGlassContainer<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    public init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    public var body: some View {
        #if os(macOS)
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        GlassEffectContainer(spacing: spacing) { content }
        #endif
    }
}

public struct PalCloseButton: View {
    private let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    @ViewBuilder
    public var body: some View {
        #if os(macOS)
        if #available(macOS 26, *) {
            Button(role: .close, action: action)
        } else {
            Button("Close", role: .cancel, action: action)
                .keyboardShortcut(.cancelAction)
        }
        #else
        Button(role: .close, action: action)
        #endif
    }
}

#if os(iOS)
public struct PalToolbarSpacer: ToolbarContent {
    private let placement: ToolbarItemPlacement

    public init(placement: ToolbarItemPlacement) {
        self.placement = placement
    }

    public var body: some ToolbarContent {
        ToolbarSpacer(.fixed, placement: placement)
    }
}
#endif

public extension View {
    @ViewBuilder
    func palPrincipalToolbarItem<Item: View>(
        isPresented: Bool = true,
        @ViewBuilder _ item: () -> Item
    ) -> some View {
        let item = item()
        if #available(macOS 26, *) {
            toolbar {
                if isPresented {
                    ToolbarItem(placement: .principal) { item }.sharedBackgroundVisibility(.hidden)
                }
            }
        } else {
            toolbar {
                if isPresented {
                    ToolbarItem(placement: .principal) { item }
                }
            }
        }
    }
}

public extension View {
    @ViewBuilder
    func palSafeAreaBar<Bar: View>(
        edge: VerticalEdge,
        alignment: HorizontalAlignment = .center,
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> Bar
    ) -> some View {
        #if os(macOS)
        if #available(macOS 26, *) {
            safeAreaBar(edge: edge, alignment: alignment, spacing: spacing, content: content)
        } else {
            safeAreaInset(edge: edge, alignment: alignment, spacing: spacing, content: content)
        }
        #else
        safeAreaBar(edge: edge, alignment: alignment, spacing: spacing, content: content)
        #endif
    }

    @ViewBuilder
    func palSoftScrollEdge(for edges: Edge.Set) -> some View {
        #if os(macOS)
        if #available(macOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            self
        }
        #else
        scrollEdgeEffectStyle(.soft, for: edges)
        #endif
    }

    @ViewBuilder
    func palHiddenScrollEdge(for edges: Edge.Set) -> some View {
        #if os(macOS)
        if #available(macOS 26, *) {
            scrollEdgeEffectHidden(true, for: edges)
        } else {
            self
        }
        #else
        scrollEdgeEffectHidden(true, for: edges)
        #endif
    }
}
