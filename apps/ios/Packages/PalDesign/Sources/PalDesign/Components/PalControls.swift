import SwiftUI

public extension View {
    func palGlass<S: Shape>(_ shape: S, interactive: Bool = true) -> some View {
        glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
    }
}

public extension View {
    @ViewBuilder
    func glassButtonStyle(prominent: Bool, tint: Color = PalTokens.textPrimary) -> some View {
        if prominent {
            buttonStyle(.glassProminent).tint(tint).foregroundStyle(PalTokens.content)
        } else {
            buttonStyle(.glass)
        }
    }
}

extension View {
    public func minimumHitTarget(visual side: CGFloat) -> some View {
        contentShape(Rectangle().inset(by: -max(0, (ChatMetrics.minimumHitTarget - side) / 2)))
    }
}
