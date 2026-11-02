import Foundation

enum BlobGeometry {
    struct Body {
        var cx: Double
        var cy: Double
        var rx: Double
        var ry: Double
        var n: Double
        var rot: Double
        var radii: [Double]
        var sides: Int = 0
        var round: Double = 0
    }

    private static func r2(_ value: Double) -> String { JSCompat.r2String(value) }

    static func superellipse(cx: Double, cy: Double, rx: Double, ry: Double, n: Double = 4, rot: Double = 0) -> String {
        let k = min(1, (8 * pow(2, -1 / n) - 4) / 3)
        let a = rx
        let b = ry
        let ak = a * k
        let bk = b * k
        let points: [(Double, Double)] = [
            (a, 0),
            (a, bk), (ak, b), (0, b),
            (-ak, b), (-a, bk), (-a, 0),
            (-a, -bk), (-ak, -b), (0, -b),
            (ak, -b), (a, -bk), (a, 0),
        ]
        let angle = (rot * Double.pi) / 180
        let cosine = cos(angle)
        let sine = sin(angle)
        func at(_ index: Int) -> String {
            let (x, y) = points[index]
            return "\(r2(cx + x * cosine - y * sine)) \(r2(cy + x * sine + y * cosine))"
        }
        var d = "M\(at(0))"
        var index = 1
        while index < 13 {
            d += "C\(at(index)) \(at(index + 1)) \(at(index + 2))"
            index += 3
        }
        return d + "Z"
    }

    static func superellipse(_ body: Body) -> String {
        superellipse(cx: body.cx, cy: body.cy, rx: body.rx, ry: body.ry, n: body.n, rot: body.rot)
    }

    static func spline(_ body: Body) -> String {
        let count = body.radii.count
        let start = (body.rot * Double.pi) / 180
        let points: [(Double, Double)] = body.radii.enumerated().map { index, multiplier in
            let angle = start + (2 * Double.pi * Double(index)) / Double(count)
            return (body.cx + body.rx * multiplier * cos(angle), body.cy + body.ry * multiplier * sin(angle))
        }
        func at(_ index: Int) -> (Double, Double) { points[((index % count) + count) % count] }
        var d = "M\(r2(at(0).0)) \(r2(at(0).1))"
        for index in 0..<count {
            let (x0, y0) = at(index - 1)
            let (x1, y1) = at(index)
            let (x2, y2) = at(index + 1)
            let (x3, y3) = at(index + 2)
            d += "C\(r2(x1 + (x2 - x0) / 6)) \(r2(y1 + (y2 - y0) / 6))"
                + " \(r2(x2 - (x3 - x1) / 6)) \(r2(y2 - (y3 - y1) / 6))"
                + " \(r2(x2)) \(r2(y2))"
        }
        return d + "Z"
    }

    static func polygon(_ body: Body) -> String {
        let sides = body.sides
        let roundness = body.round
        let k = roundness > 0 ? (roundness < 1 ? roundness / 2 : 0.5) : 0
        let start = (body.rot * Double.pi) / 180 - Double.pi / 2
        let vertices: [(Double, Double)] = (0..<sides).map { index in
            let angle = start + (2 * Double.pi * Double(index)) / Double(sides)
            return (body.cx + body.rx * cos(angle), body.cy + body.ry * sin(angle))
        }
        func at(_ index: Int) -> (Double, Double) { vertices[((index % sides) + sides) % sides] }
        func cut(_ from: Int, _ to: Int) -> String {
            let (x0, y0) = at(from)
            let (x1, y1) = at(to)
            return "\(r2(x0 + (x1 - x0) * k)) \(r2(y0 + (y1 - y0) * k))"
        }
        var d = "M\(cut(0, -1))"
        for index in 0..<sides {
            let (x, y) = at(index)
            d += "Q\(r2(x)) \(r2(y)) \(cut(index, index + 1))"
            if k < 0.5 { d += "L\(cut(index + 1, index))" }
        }
        return d + "Z"
    }

    static func box(_ body: Body) -> String {
        let cx = body.cx
        let cy = body.cy
        let rx = body.rx - body.ry
        let ry = body.ry
        let left = r2(cx - rx)
        let right = r2(cx + rx)
        return "M\(left) \(r2(cy - ry))H\(right)V\(r2(cy + ry))H\(left)Z"
    }

    static func taper(cx: Double, cy: Double, rx: Double, ry: Double, tip: Double) -> String {
        let t = max(1.05, tip)
        let tx = rx * (1 - 1 / (t * t)).squareRoot()
        let ty = cy - ry / t
        let apex = cy - t * ry
        let px = tx * 0.14
        let py = ty + 0.86 * (apex - ty)
        return "M\(r2(cx - tx)) \(r2(ty))"
            + "L\(r2(cx - px)) \(r2(py))"
            + "Q\(r2(cx)) \(r2(apex)) \(r2(cx + px)) \(r2(py))"
            + "L\(r2(cx + tx)) \(r2(ty))Z"
    }
}
