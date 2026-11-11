import CoreGraphics
import Synchronization
import SwiftUI

private struct Vector3 {
    var x: Double
    var y: Double
    var z: Double

    static func + (a: Vector3, b: Vector3) -> Vector3 { Vector3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    static func - (a: Vector3, b: Vector3) -> Vector3 { Vector3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    static func * (a: Vector3, k: Double) -> Vector3 { Vector3(x: a.x * k, y: a.y * k, z: a.z * k) }
}

struct EyeSurface: Sendable {
    static let cells = 48
    static let curveSteps = 8
    static let walkSteps = 12
    static let bulge = 1.3

    private static let built = Mutex<[String: EyeSurface]>([:])
    private static let remembered = 64

    static func shared(mask: [AvatarDrawing.Element]) -> EyeSurface {
        let key = mask.map { "\($0.fill != nil) \($0.stroke?.width ?? 0) \($0.path.description)" }.joined(separator: "|")
        if let known = built.withLock({ $0[key] }) { return known }
        let surface = EyeSurface(mask: mask)
        built.withLock { cache in
            if cache.count >= remembered { cache.removeAll() }
            cache[key] = surface
        }
        return surface
    }

    private struct Dome: Sendable {
        var deepest: Double
        var depths: [Double]
    }

    private let origin: CGPoint
    private let cell: CGSize
    private let domes: [Dome]

    init(mask: [AvatarDrawing.Element]) {
        let box = AvatarRig.bounds(of: mask).insetBy(dx: -1, dy: -1)
        guard !box.isNull, box.width > 0, box.height > 0 else {
            origin = .zero
            cell = .zero
            domes = []
            return
        }
        let cell = CGSize(width: box.width / Double(Self.cells), height: box.height / Double(Self.cells))
        let nodes = (0...Self.cells).flatMap { row in
            (0...Self.cells).map { column in
                CGPoint(x: box.minX + Double(column) * cell.width, y: box.minY + Double(row) * cell.height)
            }
        }
        origin = box.origin
        self.cell = cell
        domes = mask.filter { $0.fill != nil }.compactMap { element in
            let outlines = Self.outlines(of: element.path)
            let reach = (element.stroke?.width ?? 0) / 2
            let depths = nodes.map { Self.depth(of: $0, in: outlines) + reach }
            guard let deepest = depths.max(), deepest > 0 else { return nil }
            return Dome(deepest: deepest, depths: depths)
        }
    }

    func project(_ path: Path, around centre: CGPoint) -> Path {
        var projected = Path()
        guard height(at: centre) > 0 else { return projected }
        for outline in Self.outlines(of: path) {
            let placed = outline.map { place(CGVector(dx: $0.x - centre.x, dy: $0.y - centre.y), from: centre) }
            projected.move(to: placed[0])
            for point in placed.dropFirst() { projected.addLine(to: point) }
            projected.closeSubpath()
        }
        return projected
    }

    func clearance(at point: CGPoint) -> Double {
        guard cell.width > 0, cell.height > 0 else { return -1 }
        let x = (point.x - origin.x) / cell.width
        let y = (point.y - origin.y) / cell.height
        guard x >= 0, y >= 0, x <= Double(Self.cells), y <= Double(Self.cells) else { return -1 }
        let column = min(Int(x), Self.cells - 1)
        let row = min(Int(y), Self.cells - 1)
        let fx = x - Double(column)
        let fy = y - Double(row)
        let stride = Self.cells + 1
        let corner = row * stride + column
        return domes.reduce(-1) { best, dome in
            let top = dome.depths[corner] * (1 - fx) + dome.depths[corner + 1] * fx
            let bottom = dome.depths[corner + stride] * (1 - fx) + dome.depths[corner + stride + 1] * fx
            return max(best, top * (1 - fy) + bottom * fy)
        }
    }

    func height(at point: CGPoint) -> Double {
        guard cell.width > 0, cell.height > 0 else { return 0 }
        let x = (point.x - origin.x) / cell.width
        let y = (point.y - origin.y) / cell.height
        guard x >= 0, y >= 0, x <= Double(Self.cells), y <= Double(Self.cells) else { return 0 }
        let column = min(Int(x), Self.cells - 1)
        let row = min(Int(y), Self.cells - 1)
        let fx = x - Double(column)
        let fy = y - Double(row)
        let stride = Self.cells + 1
        let corner = row * stride + column
        return domes.reduce(0) { highest, dome in
            let top = dome.depths[corner] * (1 - fx) + dome.depths[corner + 1] * fx
            let bottom = dome.depths[corner + stride] * (1 - fx) + dome.depths[corner + stride + 1] * fx
            let depth = top * (1 - fy) + bottom * fy
            guard depth > 0 else { return highest }
            return max(highest, Self.bulge * sqrt(depth * (2 * dome.deepest - depth)))
        }
    }

    private func place(_ offset: CGVector, from centre: CGPoint) -> CGPoint {
        let length = hypot(offset.dx, offset.dy)
        guard length > 0 else { return centre }
        let normal = self.normal(at: centre)
        let across = Self.unit(Vector3(x: 1, y: 0, z: 0) - normal * normal.x)
        let down = Self.cross(normal, across)
        var heading = Self.unit((across * offset.dx + down * offset.dy) * (1 / length))
        var here = Vector3(x: centre.x, y: centre.y, z: height(at: centre))
        let step = length / Double(Self.walkSteps)
        for _ in 0..<Self.walkSteps {
            let ahead = here + heading * step
            let ground = height(at: CGPoint(x: ahead.x, y: ahead.y))
            guard ground > 0 else { break }
            here = Vector3(x: ahead.x, y: ahead.y, z: ground)
            let tangent = self.normal(at: CGPoint(x: here.x, y: here.y))
            heading = Self.unit(heading - tangent * Self.dot(heading, tangent))
        }
        return CGPoint(x: here.x, y: here.y)
    }

    private func normal(at point: CGPoint) -> Vector3 {
        let reach = min(cell.width, cell.height) / 2
        let slopeX = (height(at: CGPoint(x: point.x + reach, y: point.y)) - height(at: CGPoint(x: point.x - reach, y: point.y))) / (2 * reach)
        let slopeY = (height(at: CGPoint(x: point.x, y: point.y + reach)) - height(at: CGPoint(x: point.x, y: point.y - reach))) / (2 * reach)
        return Self.unit(Vector3(x: -slopeX, y: -slopeY, z: 1))
    }

    private static func unit(_ v: Vector3) -> Vector3 {
        let length = sqrt(dot(v, v))
        return length > 0 ? v * (1 / length) : v
    }

    private static func dot(_ a: Vector3, _ b: Vector3) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    private static func cross(_ a: Vector3, _ b: Vector3) -> Vector3 {
        Vector3(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x)
    }

    private static func depth(of point: CGPoint, in outlines: [[CGPoint]]) -> Double {
        var inside = false
        var nearest = Double.infinity
        for outline in outlines {
            for (index, end) in outline.enumerated() {
                let start = outline[(index + outline.count - 1) % outline.count]
                if (start.y > point.y) != (end.y > point.y),
                   point.x < start.x + (point.y - start.y) / (end.y - start.y) * (end.x - start.x) {
                    inside.toggle()
                }
                nearest = min(nearest, distance(from: point, toSegment: start, end))
            }
        }
        return inside ? nearest : -nearest
    }

    private static func distance(from point: CGPoint, toSegment start: CGPoint, _ end: CGPoint) -> Double {
        let ex = end.x - start.x
        let ey = end.y - start.y
        let span = ex * ex + ey * ey
        let t = span > 0 ? max(0, min(1, ((point.x - start.x) * ex + (point.y - start.y) * ey) / span)) : 0
        return hypot(point.x - start.x - ex * t, point.y - start.y - ey * t)
    }

    static func outlines(of path: Path) -> [[CGPoint]] {
        var outlines: [[CGPoint]] = []
        var current: [CGPoint] = []
        var cursor = CGPoint.zero
        func trace(_ point: (Double) -> CGPoint) {
            current += (1...curveSteps).map { point(Double($0) / Double(curveSteps)) }
        }
        func finish() {
            if current.count > 2 { outlines.append(current) }
            current = []
        }
        path.forEach { element in
            let start = cursor
            switch element {
            case .move(let to):
                finish()
                current = [to]
                cursor = to
            case .line(let to):
                trace { line(start, to, $0) }
                cursor = to
            case .quadCurve(let to, let control):
                trace { line(line(start, control, $0), line(control, to, $0), $0) }
                cursor = to
            case .curve(let to, let first, let second):
                trace { cubic(start, first, second, to, $0) }
                cursor = to
            case .closeSubpath:
                if let first = current.first {
                    trace { line(start, first, $0) }
                    current.removeLast()
                    cursor = first
                }
                finish()
            }
        }
        finish()
        return outlines
    }

    private static func line(_ from: CGPoint, _ to: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
    }

    private static func cubic(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: Double) -> CGPoint {
        line(line(line(p0, p1, t), line(p1, p2, t), t), line(line(p1, p2, t), line(p2, p3, t), t), t)
    }
}
