import SwiftUI

public struct SlackMark: View {
    public enum Style: Sendable {
        case brand
        case mono(Color)
    }

    public let style: Style

    private static let side: CGFloat = 122.8
    private static let radius: CGFloat = 12.9

    private static let red = Color(red: 0.878, green: 0.118, blue: 0.353)
    private static let blue = Color(red: 0.212, green: 0.773, blue: 0.941)
    private static let green = Color(red: 0.180, green: 0.714, blue: 0.490)
    private static let yellow = Color(red: 0.925, green: 0.698, blue: 0.180)

    private enum Corner {
        case topRight, bottomRight, bottomLeft, topLeft
    }

    private static func pill(_ rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: radius)
    }

    private static func bud(center: CGPoint, squared corner: Corner) -> Path {
        var path = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        let square: CGRect
        switch corner {
        case .topRight: square = CGRect(x: center.x, y: center.y - radius, width: radius, height: radius)
        case .bottomRight: square = CGRect(x: center.x, y: center.y, width: radius, height: radius)
        case .bottomLeft: square = CGRect(x: center.x - radius, y: center.y, width: radius, height: radius)
        case .topLeft: square = CGRect(x: center.x - radius, y: center.y - radius, width: radius, height: radius)
        }
        path.addRect(square)
        return path
    }

    private static let pieces: [(color: Color, path: Path)] = [
        (red, bud(center: CGPoint(x: 12.9, y: 77.6), squared: .topRight)),
        (red, pill(CGRect(x: 32.3, y: 64.7, width: 25.8, height: 58.1))),
        (blue, bud(center: CGPoint(x: 45.2, y: 12.9), squared: .bottomRight)),
        (blue, pill(CGRect(x: 0, y: 32.3, width: 58.1, height: 25.8))),
        (green, bud(center: CGPoint(x: 109.9, y: 45.2), squared: .bottomLeft)),
        (green, pill(CGRect(x: 64.7, y: 0, width: 25.8, height: 58.1))),
        (yellow, bud(center: CGPoint(x: 77.6, y: 109.9), squared: .topLeft)),
        (yellow, pill(CGRect(x: 64.7, y: 64.7, width: 58.1, height: 25.8))),
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
                let path = piece.path.applying(placement)
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
