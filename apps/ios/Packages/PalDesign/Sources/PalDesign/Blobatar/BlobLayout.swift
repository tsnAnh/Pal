import Foundation

struct BlobShapeSpec {
    enum Path { case superellipse, spline, polygon, box }
    enum Face { case body, spline, polygon, shrunk(Double), droplet, triangle }

    let kind: BlobKind
    let core: Double
    let outline: Path
    let face: Face

    func path(_ body: BlobGeometry.Body) -> String {
        switch outline {
        case .superellipse: BlobGeometry.superellipse(body)
        case .spline: BlobGeometry.spline(body)
        case .polygon: BlobGeometry.polygon(body)
        case .box: BlobGeometry.box(body)
        }
    }
}

struct BlobLayout {
    struct Ellipse {
        var cx: Double
        var cy: Double
        var rx: Double
        var ry: Double
    }

    let shape: BlobShapeSpec
    let body: BlobGeometry.Body
    let face: Ellipse
    let petals: [BlobFigure.Petal]
    let extra: [String]
    let eyes: [BlobFigure.Eye]

    private static let bands: [(BlobShapeSpec, Double)] = [
        (BlobShapeSpec(kind: .round, core: 1, outline: .superellipse, face: .body), 0.22),
        (BlobShapeSpec(kind: .organic, core: 0.98, outline: .spline, face: .spline), 0.48),
        (BlobShapeSpec(kind: .boxy, core: 0.86, outline: .superellipse, face: .body), 0.6),
        (BlobShapeSpec(kind: .capsule, core: 1.02, outline: .box, face: .shrunk(0.94)), 0.7),
        (BlobShapeSpec(kind: .nub, core: 0.88, outline: .superellipse, face: .body), 0.79),
        (BlobShapeSpec(kind: .cloud, core: 0.78, outline: .spline, face: .spline), 0.86),
        (BlobShapeSpec(kind: .droplet, core: 0.78, outline: .superellipse, face: .droplet), 0.915),
        (BlobShapeSpec(kind: .hexagon, core: 1.05, outline: .polygon, face: .polygon), 0.95),
        (BlobShapeSpec(kind: .sun, core: 0.7, outline: .superellipse, face: .body), 0.98),
        (BlobShapeSpec(kind: .triangle, core: 1.15, outline: .polygon, face: .triangle), 1),
    ]

    static func make(_ t: BlobTraits) -> BlobLayout {
        let roll = t("shape")
        let shape = (bands.first { roll < $0.1 } ?? bands[bands.count - 1]).0
        let r = t.num("body.r", 31, 38) * shape.core
        let pointCount = t.int("body.pts", 6, 8)
        var body = BlobGeometry.Body(
            cx: 50 + t.jitter("body.x", 1.5),
            cy: 50 + t.jitter("body.y", 1.5),
            rx: r,
            ry: r * t.num("body.ratio", 0.92, 1.08),
            n: t.num("body.n", 1.9, 2.5),
            rot: 0,
            radii: (0..<pointCount).map { 1 + t.jitter("body.r\($0)", 0.16) }
        )

        adjustBody(shape.kind, t, &body)
        let face = faceRegion(shape, body)
        var petals: [BlobFigure.Petal] = []
        var extra: [String] = []
        decorate(shape.kind, t, body, &petals, &extra)

        return BlobLayout(shape: shape, body: body, face: face, petals: petals, extra: extra, eyes: fit(t, body, face))
    }

    private static func adjustBody(_ kind: BlobKind, _ t: BlobTraits, _ body: inout BlobGeometry.Body) {
        switch kind {
        case .boxy:
            body.n = t.num("body.n", 3.4, 6)
            body.rot = t.num("body.rot", -20, 20)
        case .capsule:
            body.ry *= t.num("capsule.squat", 0.55, 0.68)
        case .droplet:
            body.cy += 0.22 * body.ry
            body.n = 2
        case .hexagon:
            body.sides = 6
            body.rot = t.num("body.rot", -12, 12)
            body.round = t.num("poly.round", 0.24, 0.5)
        case .triangle:
            body.sides = 3
            body.rot = t.num("body.rot", -5, 5)
            body.round = t.num("poly.round", 0.24, 0.5)
        case .round, .organic, .nub, .cloud, .sun, .spark, .clover, .burst, .gem:
            break
        }
    }

    private static func shrunk(_ factor: Double, _ body: BlobGeometry.Body) -> Ellipse {
        Ellipse(cx: body.cx, cy: body.cy, rx: body.rx * factor, ry: body.ry * factor)
    }

    private static func faceRegion(_ shape: BlobShapeSpec, _ body: BlobGeometry.Body) -> Ellipse {
        switch shape.face {
        case .body:
            Ellipse(cx: body.cx, cy: body.cy, rx: body.rx, ry: body.ry)
        case .spline:
            shrunk((body.radii.min() ?? 1) * 0.95, body)
        case .polygon:
            shrunk(0.84, body)
        case .shrunk(let factor):
            shrunk(factor, body)
        case .droplet:
            Ellipse(cx: body.cx, cy: body.cy + body.ry * 0.05, rx: body.rx * 0.88, ry: body.ry * 0.88)
        case .triangle:
            Ellipse(cx: body.cx, cy: body.cy + body.ry * 0.1, rx: body.rx * 0.54, ry: body.ry * 0.36)
        }
    }

    private static func decorate(
        _ kind: BlobKind, _ t: BlobTraits, _ b: BlobGeometry.Body,
        _ petals: inout [BlobFigure.Petal], _ extra: inout [String]
    ) {
        switch kind {
        case .capsule:
            for side in [-1.0, 1.0] {
                petals.append(.init(cx: b.cx + side * (b.rx - b.ry), cy: b.cy, r: b.ry))
            }
        case .nub:
            let count = t.int("nub.n", 1, 2)
            for i in 0..<count {
                let angle = t.num("nub.a\(i)", 0, 2 * Double.pi)
                petals.append(.init(
                    cx: b.cx + cos(angle) * b.rx * 0.88,
                    cy: b.cy + sin(angle) * b.rx * 0.88,
                    r: b.rx * t.num("nub.r\(i)", 0.24, 0.4)
                ))
            }
        case .cloud:
            let count = t.int("cloud.n", 4, 6)
            for i in 0..<count {
                let angle = Double.pi + (Double.pi * (Double(i) + 0.5)) / Double(count)
                petals.append(.init(
                    cx: b.cx + cos(angle) * b.rx * 0.8,
                    cy: b.cy + sin(angle) * b.rx * 0.5,
                    r: b.rx * t.num("cloud.r\(i)", 0.44, 0.62)
                ))
            }
        case .droplet:
            extra.append(BlobGeometry.taper(cx: b.cx, cy: b.cy, rx: b.rx, ry: b.ry, tip: t.num("droplet.tip", 1.4, 1.65)))
        case .sun:
            let count = t.int("sun.n", 6, 9)
            let dist = b.rx * t.num("sun.dist", 1.0, 1.08)
            let radius = b.rx * t.num("sun.r", 0.2, 0.26)
            let offset = t.num("sun.rot", 0, 2 * Double.pi)
            for i in 0..<count {
                let angle = offset + (2 * Double.pi * Double(i)) / Double(count)
                petals.append(.init(cx: b.cx + cos(angle) * dist, cy: b.cy + sin(angle) * dist, r: radius))
            }
        case .round, .organic, .boxy, .hexagon, .triangle, .spark, .clover, .burst, .gem:
            break
        }
    }

    private static func fit(_ t: BlobTraits, _ b: BlobGeometry.Body, _ face: Ellipse) -> [BlobFigure.Eye] {
        let rx = b.rx
        let er0 = t.num("eye.rx", 0.075, 0.105) * rx
        let ratio = t.num("eye.ratio", 1.9, 3.2)
        let scale = t.num("eye.scale", 0.78, 1.24)
        let stretch = t.num("eye.stretch", 0.85, 1.18)
        let clearance = t.num("eye.gap", 0.1, 0.24) * rx
        let wide = er0 * max(1, scale)
        let tall = er0 * ratio * max(1, scale * stretch)
        let gap0 = wide + rx * 0.03 + clearance
        let gx = t.jitter("gaze.x", 0.09) * face.rx
        let gy = t.num("gaze.y", -0.2, 0.08) * face.ry
        let dy = t.jitter("eye.dy", 0.04) * face.ry
        let reach = hypot(wide, tall)
        let need = hypot(
            (abs(gx) + gap0 + reach) / face.rx,
            (abs(gy) + abs(dy) + reach) / face.ry
        )
        let fit = need > 0.9 ? 0.9 / need : 1

        let er = er0 * fit
        let eyeRy = er * ratio
        let gap = gap0 * fit
        let room = max(0, min(1, clearance / tall))
        let bound = min(12, (asin(room) * 180) / Double.pi)
        let lean = t.num("eye.lean", -1, 1) * bound
        let lean2 = max(-12, min(12, lean + t.jitter("eye.lean2", 3.5)))

        let cx = face.cx + gx * fit
        let cy = face.cy + gy * fit
        return [
            .init(cx: cx - gap, cy: cy, rx: er, ry: eyeRy, n: t.num("eye.n", 3.5, 6), rot: lean),
            .init(
                cx: cx + gap, cy: cy + dy * fit,
                rx: er * scale, ry: eyeRy * scale * stretch,
                n: t.num("eye.n", 3.5, 6), rot: lean2
            ),
        ]
    }
}
