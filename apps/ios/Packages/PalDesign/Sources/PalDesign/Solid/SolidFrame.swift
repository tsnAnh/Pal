import CoreGraphics
import Foundation
import SwiftUI
import simd

struct SolidRotation {
    let matrix: simd_double3x3

    init(yaw: Double, pitch: Double, roll: Double) {
        let radians = Double.pi / 180
        let b = yaw * radians
        let a = -pitch * radians
        let c = -roll * radians
        let turnY = simd_double3x3(columns: (SIMD3(cos(b), 0, -sin(b)), SIMD3(0, 1, 0), SIMD3(sin(b), 0, cos(b))))
        let turnX = simd_double3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, cos(a), sin(a)), SIMD3(0, -sin(a), cos(a))))
        let turnZ = simd_double3x3(columns: (SIMD3(cos(c), sin(c), 0), SIMD3(-sin(c), cos(c), 0), SIMD3(0, 0, 1)))
        matrix = turnY * turnX * turnZ
    }
}

struct SolidFrame: Sendable {
    let silhouette: Path
    let eyes: [Path]
    let eyeOpacity: Double
    let eyesNearEdge: Bool
    private let visibleTriangles: [Int32]
    private let corners: [CGPoint]

    init(solid: AvatarSolid, pose: SolidPose, projection: SolidProjection) {
        let geometry = solid.geometry
        let rotation = SolidRotation(yaw: pose.yaw, pitch: pose.pitch, roll: pose.roll).matrix
        var flat: [SIMD2<Double>] = []
        flat.reserveCapacity(geometry.vertices.count)
        for vertex in geometry.vertices {
            let turned = rotation * vertex
            flat.append(SIMD2(turned.x, turned.y))
        }
        let corners = flat.map(projection.point)
        var visible: [Int32] = []
        visible.reserveCapacity(geometry.triangles.count / 2)
        let path = CGMutablePath()
        var index = 0
        let triangles = geometry.triangles
        while index < triangles.count {
            let a = Int(triangles[index])
            let b = Int(triangles[index + 1])
            let c = Int(triangles[index + 2])
            index += 3
            let ab = flat[b] - flat[a]
            let ac = flat[c] - flat[a]
            guard ab.x * ac.y - ab.y * ac.x > 1e-12 else { continue }
            visible.append(Int32(a))
            visible.append(Int32(b))
            visible.append(Int32(c))
            path.move(to: corners[a])
            path.addLine(to: corners[b])
            path.addLine(to: corners[c])
            path.closeSubpath()
        }
        silhouette = Path(path)
        visibleTriangles = visible
        self.corners = corners
        let pair = SolidEyes.pair(pose, geometry: geometry, rotation: rotation)
        eyes = pair.outlines.map { Self.rounded($0.map(projection.point)) }
        eyeOpacity = pair.opacity
        eyesNearEdge = pair.nearEdge
    }

    private static func rounded(_ points: [CGPoint]) -> Path {
        var shape = Path()
        guard let last = points.last, let first = points.first else { return shape }
        func middle(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        shape.move(to: middle(last, first))
        for (index, point) in points.enumerated() {
            shape.addQuadCurve(to: middle(point, points[(index + 1) % points.count]), control: point)
        }
        shape.closeSubpath()
        return shape
    }

    func boundary() -> Path {
        var uses: [UInt64: Int] = [:]
        func edge(_ a: Int32, _ b: Int32) -> UInt64 {
            let low = UInt64(UInt32(bitPattern: min(a, b)))
            let high = UInt64(UInt32(bitPattern: max(a, b)))
            return low << 32 | high
        }
        var index = 0
        while index < visibleTriangles.count {
            let a = visibleTriangles[index]
            let b = visibleTriangles[index + 1]
            let c = visibleTriangles[index + 2]
            index += 3
            for key in [edge(a, b), edge(b, c), edge(c, a)] { uses[key, default: 0] += 1 }
        }
        let path = CGMutablePath()
        for (key, count) in uses where count == 1 {
            path.move(to: corners[Int(key >> 32)])
            path.addLine(to: corners[Int(key & 0xFFFF_FFFF)])
        }
        return Path(path)
    }
}
