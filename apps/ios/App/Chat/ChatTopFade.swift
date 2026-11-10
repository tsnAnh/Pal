import SwiftUI

struct ChatTopFade: View {
    let color: Color
    let height: CGFloat

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: color, location: 0),
                .init(color: color.opacity(0.85), location: 0.45),
                .init(color: color.opacity(0), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
