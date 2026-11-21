import SwiftUI

extension View {
    public func palSwitch() -> some View {
        toggleStyle(.switch).tint(PalTokens.toggleOn)
    }
}
