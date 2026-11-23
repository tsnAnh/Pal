import SwiftUI

public extension View {
    @ViewBuilder
    func palGlass<S: Shape>(_ shape: S, interactive: Bool = true) -> some View {
        #if os(macOS)
        if #available(macOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
        #else
        glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        #endif
    }
}

public extension View {
    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false, tint: Color = PalTokens.textPrimary) -> some View {
        #if os(macOS)
        if #available(macOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent).tint(tint).foregroundStyle(PalTokens.content)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent).tint(tint).foregroundStyle(PalTokens.content)
        } else {
            buttonStyle(.bordered)
        }
        #else
        if prominent {
            buttonStyle(.glassProminent).tint(tint).foregroundStyle(PalTokens.content)
        } else {
            buttonStyle(.glass)
        }
        #endif
    }
}

public extension View {
    @ViewBuilder
    func interactiveGlassButtonStyle() -> some View {
        #if os(macOS)
        if #available(macOS 26, *) {
            buttonStyle(.glass(.regular.interactive()))
        } else {
            buttonStyle(.bordered)
        }
        #else
        buttonStyle(.glass(.regular.interactive()))
        #endif
    }
}

extension View {
    public func minimumHitTarget(visual side: CGFloat) -> some View {
        contentShape(Rectangle().inset(by: -max(0, (ChatMetrics.minimumHitTarget - side) / 2)))
    }
}
