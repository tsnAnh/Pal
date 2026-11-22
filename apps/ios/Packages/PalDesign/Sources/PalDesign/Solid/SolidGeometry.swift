import CoreGraphics
import Foundation
import PalDiagnostics
import Synchronization
import SwiftUI

struct SolidGeometry: Sendable {
    enum Detail: Sendable {
        case standard
        case fine

        static let fineFromSize: CGFloat = 200

        init(size: CGFloat) {
            self = size >= Self.fineFromSize ? .fine : .standard
        }

        var rim: Int { self == .fine ? 288 : 96 }
        var rings: Int { self == .fine ? 32 : 8 }
    }

    static let walkSteps = 12
    static let slopeReach = 0.01

    struct Signature: Hashable, Sendable {
        let values: [Double]

        init(_ rig: AvatarRig) {
            var values: [Double] = [rig.restTilt, rig.pivot.x, rig.pivot.y]
            for element in rig.body {
                values.append(contentsOf: [6, element.fill == nil ? 0 : 1, element.stroke?.width ?? -1, element.stroke?.round == true ? 1 : 0])
                element.path.forEach { step in
                    switch step {
                    case .move(let to): values.append(contentsOf: [1, to.x, to.y])
                    case .line(let to): values.append(contentsOf: [2, to.x, to.y])
                    case .quadCurve(let to, let control): values.append(contentsOf: [3, to.x, to.y, control.x, control.y])
                    case .curve(let to, let first, let second):
                        values.append(contentsOf: [4, to.x, to.y, first.x, first.y, second.x, second.y])
                    case .closeSubpath: values.append(5)
                    }
                }
            }
            self.values = values
        }
    }

    private struct Key: Hashable, Sendable {
        let detail: Detail
        let signature: Signature
    }

    private static let nextIdentity = Atomic<UInt64>(0)

    let identity: UInt64
    let centre: CGPoint
    let radius: Double
    let surface: SolidSurface
    let vertices: [SIMD3<Double>]
    let triangles: [Int32]

    private static let built = Mutex<[Key: SolidGeometry]>([:])
    private static let remembered = 64

    static func shared(for rig: AvatarRig, signature: Signature, detail: Detail = .standard) -> SolidGeometry {
        let key = Key(detail: detail, signature: signature)
        if let known = built.withLock({ $0[key] }) { return known }
        PalPerf.event("avatar.solid.geometry.build")
        let geometry = SolidGeometry(rig: rig, detail: detail)
        built.withLock { cache in
            if cache.count >= remembered { cache.removeAll() }
            cache[key] = geometry
        }
        return geometry
    }

    init(rig: AvatarRig, detail: Detail = .standard) {
        let probe = SilhouetteProbe(rig.body)
        let box = AvatarRig.bounds(of: rig.body)
        let seed = probe.interiorPoint(near: rig.pivot, in: box)
        let reach = max(box.width, box.height)
        let measured = Self.measure(probe, from: seed, reach: reach, turn: 0, count: detail.rim)
        let centre = Self.centroid(of: measured, around: seed) ?? seed
        let canonical = Self.measure(probe, from: centre, reach: reach, turn: -rig.restTilt * Double.pi / 180, count: detail.rim)
        let radius = Self.inscribedRadius(of: canonical)
        let rim = Self.smoothed(canonical).map { $0 / radius }
        identity = Self.nextIdentity.add(1, ordering: .relaxed).newValue
        self.centre = centre
        self.radius = radius
        surface = SolidSurface(rim: rim)
        (vertices, triangles) = Self.mesh(surface: surface, rings: detail.rings)
    }

    private static func mesh(surface: SolidSurface, rings: Int) -> ([SIMD3<Double>], [Int32]) {
        let rim = surface.rim
        let count = rim.count
        var vertices: [SIMD3<Double>] = []
        var triangles: [Int32] = []
        for side in [1.0, -1.0] {
            let base = Int32(vertices.count)
            vertices.append(SIMD3(0, 0, side))
            for ring in 1...rings {
                let fraction = 1 - pow(1 - Double(ring) / Double(rings), 2)
                for angle in 0..<count {
                    let turn = Double(angle) / Double(count) * 2 * Double.pi
                    let x = cos(turn) * rim[angle] * fraction
                    let y = sin(turn) * rim[angle] * fraction
                    vertices.append(SIMD3(x, y, ring == rings ? 0 : side * surface.height(x, y)))
                }
            }
            func index(_ ring: Int, _ angle: Int) -> Int32 { base + 1 + Int32((ring - 1) * count + angle % count) }
            for angle in 0..<count {
                if side > 0 {
                    triangles += [base, index(1, angle), index(1, angle + 1)]
                } else {
                    triangles += [base, index(1, angle + 1), index(1, angle)]
                }
            }
            for ring in 1..<rings {
                for angle in 0..<count {
                    let a = index(ring, angle)
                    let b = index(ring + 1, angle)
                    let c = index(ring + 1, angle + 1)
                    let d = index(ring, angle + 1)
                    if side > 0 {
                        triangles += [a, b, c, a, c, d]
                    } else {
                        triangles += [a, c, b, a, d, c]
                    }
                }
            }
        }
        return (vertices, triangles)
    }

    private static func measure(_ probe: SilhouetteProbe, from centre: CGPoint, reach: Double, turn: Double, count: Int) -> [Double] {
        let coarse = reach / 48
        return (0..<count).map { angle in
            let theta = Double(angle) / Double(count) * 2 * Double.pi + turn
            let dx = cos(theta)
            let dy = -sin(theta)
            func covered(_ r: Double) -> Bool { probe.contains(CGPoint(x: centre.x + dx * r, y: centre.y + dy * r)) }
            var inside = 0.0
            while inside < reach, covered(inside + coarse) { inside += coarse }
            var low = inside
            var high = inside + coarse
            for _ in 0..<14 {
                let middle = (low + high) / 2
                if covered(middle) { low = middle } else { high = middle }
            }
            return max(low, coarse / 8)
        }
    }

    private static func smoothed(_ radii: [Double]) -> [Double] {
        let count = radii.count
        return radii.indices.map { (radii[($0 + count - 1) % count] + 2 * radii[$0] + radii[($0 + 1) % count]) / 4 }
    }

    private static func points(_ radii: [Double]) -> [CGPoint] {
        radii.enumerated().map { angle, radius in
            let turn = Double(angle) / Double(radii.count) * 2 * Double.pi
            return CGPoint(x: cos(turn) * radius, y: sin(turn) * radius)
        }
    }

    private static func centroid(of radii: [Double], around origin: CGPoint) -> CGPoint? {
        let outline = points(radii)
        var area = 0.0
        var sx = 0.0
        var sy = 0.0
        for (index, a) in outline.enumerated() {
            let b = outline[(index + 1) % outline.count]
            let cross = a.x * b.y - b.x * a.y
            area += cross
            sx += (a.x + b.x) * cross
            sy += (a.y + b.y) * cross
        }
        guard abs(area) > 1e-9 else { return nil }
        return CGPoint(x: origin.x + sx / (3 * area), y: origin.y - sy / (3 * area))
    }

    private static func inscribedRadius(of radii: [Double]) -> Double {
        let outline = points(radii)
        let floor = radii.min() ?? 1
        let steps = 10
        func clearance(_ p: CGPoint) -> Double {
            var nearest = Double.infinity
            for (index, a) in outline.enumerated() {
                let b = outline[(index + 1) % outline.count]
                nearest = min(nearest, distance(from: p, toSegment: a, b))
            }
            return nearest
        }
        var best = clearance(.zero)
        var centre = CGPoint.zero
        var reach = floor * 0.5
        for _ in 0..<3 {
            let origin = centre
            for row in -steps...steps {
                for column in -steps...steps {
                    let p = CGPoint(
                        x: origin.x + reach * Double(column) / Double(steps),
                        y: origin.y + reach * Double(row) / Double(steps)
                    )
                    let value = clearance(p)
                    if value > best { best = value; centre = p }
                }
            }
            reach /= Double(steps)
        }
        return best
    }

    private static func distance(from point: CGPoint, toSegment start: CGPoint, _ end: CGPoint) -> Double {
        let ex = end.x - start.x
        let ey = end.y - start.y
        let span = ex * ex + ey * ey
        let t = span > 0 ? max(0, min(1, ((point.x - start.x) * ex + (point.y - start.y) * ey) / span)) : 0
        return hypot(point.x - start.x - ex * t, point.y - start.y - ey * t)
    }
}

struct SolidSurface: Sendable {
    let rim: [Double]

    func rho(_ x: Double, _ y: Double) -> Double {
        let count = rim.count
        let turns = atan2(y, x) / (2 * Double.pi)
        let position = (turns - turns.rounded(.down)) * Double(count)
        let index = Int(position)
        let fraction = position - Double(index)
        return rim[index % count] * (1 - fraction) + rim[(index + 1) % count] * fraction
    }

    func height(_ x: Double, _ y: Double) -> Double {
        let q = (x * x + y * y).squareRoot() / rho(x, y)
        return q < 1 ? (1 - q * q).squareRoot() : 0
    }

    func normal(_ x: Double, _ y: Double) -> SIMD3<Double> {
        let e = SolidGeometry.slopeReach
        let gx = (height(x + e, y) - height(x - e, y)) / (2 * e)
        let gy = (height(x, y + e) - height(x, y - e)) / (2 * e)
        let length = (gx * gx + gy * gy + 1).squareRoot()
        return SIMD3(-gx / length, -gy / length, 1 / length)
    }

    func place(from origin: SIMD2<Double>, offset: SIMD2<Double>) -> SIMD2<Double> {
        let length = (offset.x * offset.x + offset.y * offset.y).squareRoot()
        guard length > 0, height(origin.x, origin.y) > 0 else { return origin + offset }
        let n = normal(origin.x, origin.y)
        let across = Self.unit(SIMD3(1 - n.x * n.x, -n.y * n.x, -n.z * n.x))
        let up = Self.cross(n, across)
        var heading = Self.unit((across * offset.x + up * offset.y) / length)
        var here = origin
        let step = length / Double(SolidGeometry.walkSteps)
        for _ in 0..<SolidGeometry.walkSteps {
            let ahead = SIMD2(here.x + heading.x * step, here.y + heading.y * step)
            guard height(ahead.x, ahead.y) > 0 else { break }
            here = ahead
            let tangent = normal(ahead.x, ahead.y)
            let along = (heading * tangent).sum()
            heading = Self.unit(heading - tangent * along)
        }
        return here
    }

    private static func unit(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let length = (v * v).sum().squareRoot()
        return length > 0 ? v / length : v
    }

    private static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }
}

struct SilhouetteProbe {
    private enum Stroke {
        case round(segments: [(CGPoint, CGPoint)], radius: Double)
        case outline(Path)

        func contains(_ point: CGPoint) -> Bool {
            switch self {
            case .outline(let path): return path.contains(point)
            case .round(let segments, let radius):
                let limit = radius * radius
                return segments.contains { SilhouetteProbe.squaredDistance(from: point, toSegment: $0.0, $0.1) <= limit }
            }
        }
    }

    private struct Part {
        let fill: Path?
        let stroke: Stroke?
    }

    private static let curveSteps = 48

    private let parts: [Part]

    init(_ body: [AvatarDrawing.Element]) {
        parts = body.map { element in
            Part(
                fill: element.fill == nil ? nil : element.path,
                stroke: element.stroke.map { stroke in
                    if stroke.round {
                        return .round(segments: Self.segments(of: element.path), radius: stroke.width / 2)
                    }
                    return .outline(element.path.strokedPath(StrokeStyle(lineWidth: stroke.width, lineCap: .butt, lineJoin: .miter)))
                }
            )
        }
    }

    func contains(_ point: CGPoint) -> Bool {
        parts.contains { ($0.fill?.contains(point) ?? false) || ($0.stroke?.contains(point) ?? false) }
    }

    private static func segments(of path: Path) -> [(CGPoint, CGPoint)] {
        var result: [(CGPoint, CGPoint)] = []
        var start = CGPoint.zero
        var cursor = CGPoint.zero
        func line(_ to: CGPoint) {
            result.append((cursor, to))
            cursor = to
        }
        func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        path.forEach { element in
            switch element {
            case .move(let to):
                start = to
                cursor = to
            case .line(let to):
                line(to)
            case .quadCurve(let to, let control):
                let origin = cursor
                for step in 1...curveSteps {
                    let t = Double(step) / Double(curveSteps)
                    line(lerp(lerp(origin, control, t), lerp(control, to, t), t))
                }
            case .curve(let to, let first, let second):
                let origin = cursor
                for step in 1...curveSteps {
                    let t = Double(step) / Double(curveSteps)
                    let a = lerp(origin, first, t)
                    let b = lerp(first, second, t)
                    let c = lerp(second, to, t)
                    line(lerp(lerp(a, b, t), lerp(b, c, t), t))
                }
            case .closeSubpath:
                if cursor != start { line(start) }
            }
        }
        return result
    }

    fileprivate static func squaredDistance(from point: CGPoint, toSegment start: CGPoint, _ end: CGPoint) -> Double {
        let ex = end.x - start.x
        let ey = end.y - start.y
        let span = ex * ex + ey * ey
        let t = span > 0 ? max(0, min(1, ((point.x - start.x) * ex + (point.y - start.y) * ey) / span)) : 0
        let dx = point.x - start.x - ex * t
        let dy = point.y - start.y - ey * t
        return dx * dx + dy * dy
    }

    func interiorPoint(near target: CGPoint, in box: CGRect) -> CGPoint {
        if contains(target) { return target }
        let steps = 24
        var best: CGPoint?
        for row in 0...steps {
            for column in 0...steps {
                let p = CGPoint(
                    x: box.minX + box.width * Double(column) / Double(steps),
                    y: box.minY + box.height * Double(row) / Double(steps)
                )
                guard contains(p) else { continue }
                if best.map({ hypot(p.x - target.x, p.y - target.y) < hypot($0.x - target.x, $0.y - target.y) }) ?? true { best = p }
            }
        }
        return best ?? target
    }
}
