import Foundation

struct ExtendedSilhouette: Equatable {
    var petals: [BlobFigure.Petal]
    var mainPath: String

    private struct Star {
        var points: Int
        var tip: Double
        var valley: Double
    }

    private static let stars: [BlobKind: Star] = [
        .spark: Star(points: 4, tip: 1.15, valley: 0.54),
        .burst: Star(points: 7, tip: 1.1, valley: 0.6),
    ]

    private static let gemSides = 5
    private static let gemRadius = 1.06
    private static let gemRound = 0.24
    private static let cloverReach = 0.55
    private static let cloverPetal = 0.52

    init?(_ kind: BlobKind, aroundBody pathData: String) {
        let values = JSCompat.numbers(in: pathData)
        let xs = values.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let ys = values.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        guard xs.count >= 3, ys.count >= 3, let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max()
        else { return nil }
        func rounded(_ value: Double) -> Double { Double(JSCompat.toFixed2(value)) ?? value }
        let cx = rounded((minX + maxX) / 2)
        let cy = rounded((minY + maxY) / 2)
        let r = rounded((maxX - minX + maxY - minY) / 4)
        switch kind {
        case .spark, .burst:
            guard let star = Self.stars[kind] else { return nil }
            petals = []
            mainPath = Self.starPath(star, cx: cx, cy: cy, r: r)
        case .gem:
            petals = []
            mainPath = BlobGeometry.polygon(.init(
                cx: cx, cy: cy, rx: r * Self.gemRadius, ry: r * Self.gemRadius, n: 2, rot: 0, radii: [],
                sides: Self.gemSides, round: Self.gemRound
            ))
        case .clover:
            let lobes = (0..<4).map { index -> BlobFigure.Petal in
                let angle = Double.pi / 4 + Double.pi / 2 * Double(index)
                return .init(
                    cx: cx + cos(angle) * r * Self.cloverReach,
                    cy: cy + sin(angle) * r * Self.cloverReach,
                    r: r * Self.cloverPetal
                )
            }
            petals = lobes + [.init(cx: cx, cy: cy, r: r * Self.cloverPetal)]
            mainPath = "M\(JSCompat.r2String(cx)) \(JSCompat.r2String(cy))Z"
        default:
            return nil
        }
    }

    private static func starPath(_ star: Star, cx: Double, cy: Double, r: Double) -> String {
        let count = star.points * 2
        let vertices = (0..<count).map { index -> String in
            let radius = (index.isMultiple(of: 2) ? star.tip : star.valley) * r
            let angle = -Double.pi / 2 + Double.pi * Double(index) / Double(star.points)
            return "\(JSCompat.r2String(cx + cos(angle) * radius)) \(JSCompat.r2String(cy + sin(angle) * radius))"
        }
        return "M" + vertices.joined(separator: "L") + "Z"
    }
}
