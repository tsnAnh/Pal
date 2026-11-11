import CoreGraphics
import SwiftUI

enum ClassicDrawing {
    static let viewBox = CGSize(width: 40, height: 44)

    private static let figure = CGAffineTransform.svgList([
        .svgRotate(-14, aroundX: 20, y: 20),
        .svgTranslate(20, 22),
        .svgScale(0.72),
        .svgTranslate(-20, -22),
    ])
    private static let figureScale = 0.72
    private static let bodyStroke = 13.0
    private static let eye = (width: 4.8, height: 11.4, gap: 9.4, slant: -11.0, midX: 23.4)
    private static let cloudPath =
        "M11 32 a7.5 7.5 0 0 1 -1 -14.9 A9.5 9.5 0 0 1 29 12.5 A7 7 0 0 1 30 32 Z"
    private static let dotCentres: [(Double, Double)] = [(16.4, 41.2), (20, 41.2), (23.6, 41.2)]
    private static let dotRadius = 1.15
    private static let ringSteps = 52

    static func make(_ avatar: ClassicAvatar) -> AvatarRig {
        let color = avatar.color
        let outline = avatar.shape == .cloud ? SVGPathData.path(cloudPath) : SVGPathData.path(ringData(ring(avatar.shape)))
        let body = [AvatarDrawing.Element(
            path: outline.applying(figure),
            fill: color,
            stroke: .init(color: color, width: bodyStroke * figureScale, round: true)
        )]

        let eyeLine = (avatar.shape == .cloud ? 22.0 : 17.2) - 1.6
        let rest = [eye.midX - eye.gap / 2, eye.midX + eye.gap / 2].map { centreX in
            EyePlacement(CGAffineTransform.svgList([.svgTranslate(centreX, eyeLine), .svgRotate(eye.slant)]).concatenating(figure))
        }
        let eyeSize = CGSize(width: eye.width, height: eye.height)

        let dots = dotCentres.map { centre in
            AvatarDrawing.Element(
                path: Path(ellipseIn: CGRect(
                    x: centre.0 - dotRadius, y: centre.1 - dotRadius, width: 2 * dotRadius, height: 2 * dotRadius
                )),
                fill: color,
                stroke: nil
            )
        }

        let bounds = AvatarRig.bounds(of: body)
        return AvatarRig(
            viewBox: viewBox,
            clipsToViewBox: false,
            body: body,
            eyes: .init(
                size: eyeSize,
                fill: color.eyeFill,
                rest: rest,
                facing: AvatarRig.facing(rest, size: eyeSize, bounds: bounds),
                mask: body
            ),
            dots: dots,
            bounds: bounds,
            restTilt: -14
        )
    }

    private static func ringData(_ points: [CGPoint]) -> String {
        guard let first = points.first else { return "" }
        var data = "M\(JSCompat.toFixed2(first.x)) \(JSCompat.toFixed2(first.y))"
        for point in points.dropFirst() {
            data += "L\(JSCompat.toFixed2(point.x)) \(JSCompat.toFixed2(point.y))"
        }
        return data + "Z"
    }

    private static func ring(_ shape: ClassicShape) -> [CGPoint] {
        if shape == .drop { return dropRing() }
        return (0..<ringSteps).map { index in
            let a = (Double(index) / Double(ringSteps)) * Double.pi * 2 - Double.pi / 2
            let c = cos(a)
            let s = sin(a)
            let (rx, ry) = radii(shape, angle: a, cosine: c, sine: s)
            return CGPoint(x: 20 + rx * c, y: 20 + ry * s)
        }
    }

    private static func radii(_ shape: ClassicShape, angle a: Double, cosine c: Double, sine s: Double) -> (Double, Double) {
        switch shape {
        case .blob:
            let r = 16 + 1.7 * sin(3 * a) + 0.7 * cos(5 * a)
            return (r, r)
        case .squircle:
            let d = pow(pow(abs(c), 5) + pow(abs(s), 5), 1.0 / 5)
            let r = 16.2 / (d == 0 ? 1 : d)
            return (r, r)
        case .pill:
            let d = pow(pow(abs(c), 8) + pow(abs(s / 0.72), 8), 1.0 / 8)
            let r = 16 / (d == 0 ? 1 : d)
            return (r, r)
        case .triangle:
            let u = (a + Double.pi / 2 + Double.pi * 2).truncatingRemainder(dividingBy: Double.pi * 2)
            let sector = (u / ((Double.pi * 2) / 3)).truncatingRemainder(dividingBy: 1)
            let r = 13.5 / max(0.42, cos((sector - 0.5) * 1.9))
            return (r, r)
        case .hexagon:
            let segment = Double.pi / 3
            let hex = cos(segment / 2) / cos(a - segment * JSCompat.round(a / segment))
            let r = 16.2 * hex
            return (r, r)
        case .cube:
            let d = pow(pow(abs(c), 3.1) + pow(abs(s), 3.1), 1.0 / 3.1)
            let r = 16 / (d == 0 ? 1 : d)
            return (r, r)
        case .pebble:
            return (16.4 * (1.04 - 0.14 * cos(2 * a)), 15.2 * (1.06 + 0.08 * sin(2 * a)))
        case .circle, .cloud, .drop:
            return (16.2, 16.2)
        }
    }

    private static func cubic(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: Double) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x,
            y: u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
        )
    }

    private static func dropRing() -> [CGPoint] {
        let n = max(8, ringSteps / 3)
        var points: [CGPoint] = []
        for i in 0..<n {
            points.append(cubic(CGPoint(x: 20, y: 3), CGPoint(x: 20, y: 3), CGPoint(x: 6, y: 20), CGPoint(x: 6, y: 27), Double(i) / Double(n)))
        }
        for i in 0...n {
            let t = (Double(i) / Double(n)) * Double.pi
            points.append(CGPoint(x: 20 - 14 * cos(t), y: 27 + 13.5 * sin(t)))
        }
        for i in 1...n {
            points.append(cubic(CGPoint(x: 34, y: 27), CGPoint(x: 34, y: 20), CGPoint(x: 20, y: 3), CGPoint(x: 20, y: 3), Double(i) / Double(n)))
        }
        return points
    }
}
