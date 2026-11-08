import SwiftUI

public struct SlackMark: View {
    public enum Style: Sendable {
        case brand
        case mono(Color)
    }

    public let style: Style

    private static let side: CGFloat = 122.8

    private static let pieces: [(color: Color, data: String)] = [
        (Color(red: 0.878, green: 0.118, blue: 0.353), "M25.8 77.6c0 7.1-5.8 12.9-12.9 12.9S0 84.7 0 77.6s5.8-12.9 12.9-12.9h12.9v12.9z"),
        (Color(red: 0.878, green: 0.118, blue: 0.353), "M32.3 77.6c0-7.1 5.8-12.9 12.9-12.9s12.9 5.8 12.9 12.9v32.3c0 7.1-5.8 12.9-12.9 12.9s-12.9-5.8-12.9-12.9V77.6z"),
        (Color(red: 0.212, green: 0.773, blue: 0.941), "M45.2 25.8c-7.1 0-12.9-5.8-12.9-12.9S38.1 0 45.2 0s12.9 5.8 12.9 12.9v12.9H45.2z"),
        (Color(red: 0.212, green: 0.773, blue: 0.941), "M45.2 32.3c7.1 0 12.9 5.8 12.9 12.9s-5.8 12.9-12.9 12.9H12.9C5.8 58.1 0 52.3 0 45.2s5.8-12.9 12.9-12.9h32.3z"),
        (Color(red: 0.180, green: 0.714, blue: 0.490), "M97 45.2c0-7.1 5.8-12.9 12.9-12.9s12.9 5.8 12.9 12.9-5.8 12.9-12.9 12.9H97V45.2z"),
        (Color(red: 0.180, green: 0.714, blue: 0.490), "M90.5 45.2c0 7.1-5.8 12.9-12.9 12.9s-12.9-5.8-12.9-12.9V12.9C64.7 5.8 70.5 0 77.6 0s12.9 5.8 12.9 12.9v32.3z"),
        (Color(red: 0.925, green: 0.698, blue: 0.180), "M77.6 97c7.1 0 12.9 5.8 12.9 12.9s-5.8 12.9-12.9 12.9-12.9-5.8-12.9-12.9V97h12.9z"),
        (Color(red: 0.925, green: 0.698, blue: 0.180), "M77.6 90.5c-7.1 0-12.9-5.8-12.9-12.9s5.8-12.9 12.9-12.9h32.3c7.1 0 12.9 5.8 12.9 12.9s-5.8 12.9-12.9 12.9H77.6z"),
    ]

    public init(style: Style = .brand) {
        self.style = style
    }

    public var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / Self.side
            let origin = CGPoint(x: (size.width - Self.side * scale) / 2, y: (size.height - Self.side * scale) / 2)
            let placement = CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: scale, y: scale)
            for piece in Self.pieces {
                let path = SVGPathData.path(piece.data).applying(placement)
                switch style {
                case .brand: context.fill(path, with: .color(piece.color))
                case .mono(let color): context.fill(path, with: .color(color))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
