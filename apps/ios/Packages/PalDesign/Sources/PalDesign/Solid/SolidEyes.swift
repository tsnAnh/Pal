import Foundation
import simd

struct SolidEyePair {
    var outlines: [[SIMD2<Double>]]
    var opacity: Double
    var nearEdge: Bool

    static let hidden = SolidEyePair(outlines: [], opacity: 0, nearEdge: false)
}

enum SolidEyes {
    static let segments = 40

    private struct Vertex {
        var outline: SIMD2<Double>
        var circle: SIMD2<Double>
    }

    private static let template: [Vertex] = {
        let a = SolidTuning.eye.width / 2
        let spine = max(SolidTuning.eye.height / 2 - a, 0)
        return (0..<segments).map { index in
            let t = Double(index) / Double(segments) * 2 * Double.pi
            let c = cos(t)
            let s = sin(t)
            var low = 0.0
            var high = SolidTuning.eye.height
            for _ in 0..<24 {
                let middle = (low + high) / 2
                let y = s * middle
                let clamped = max(-spine, min(spine, y))
                if hypot(c * middle, y - clamped) < a { low = middle } else { high = middle }
            }
            return Vertex(outline: SIMD2(c * low, s * low), circle: SIMD2(c * a, s * a))
        }
    }()

    static func centres(_ pose: SolidPose) -> [SIMD2<Double>] {
        let spin = pose.pairSpin * Double.pi / 180
        return [-1.0, 1.0].map { side in
            let offset = side * SolidTuning.eye.gap * pose.eyeSpread / 2
            return SIMD2(offset * cos(spin), SolidTuning.eye.y + offset * sin(spin))
        }
    }

    static func pair(_ pose: SolidPose, surface: SolidSurface, rotation: simd_double3x3) -> SolidEyePair {
        let happy = pose.eyeHappy
        let bend = happy * 5
        let turnAngle = happy * Double.pi / 2
        let ct = cos(turnAngle)
        let st = sin(turnAngle)
        let rollAngle = pose.eyeRoll * Double.pi / 180
        let cr = cos(rollAngle)
        let sr = sin(rollAngle)
        let widthScale = pose.eyeScale * (1 - 0.2 * happy)
        let heightScale = pose.eyeScale * max(0.06, pose.eyeOpen) * (1 - 0.45 * happy)
        let facingRow = SIMD3(rotation[0][2], rotation[1][2], rotation[2][2])
        var leastFacing = 1.0
        let outlines = centres(pose).map { centre in
            var projected: [SIMD2<Double>] = []
            projected.reserveCapacity(segments)
            for vertex in template {
                let u = vertex.outline.x + (vertex.circle.x - vertex.outline.x) * pose.eyeDot
                let v = vertex.outline.y + (vertex.circle.y - vertex.outline.y) * pose.eyeDot
                let a = u * widthScale
                let b = v * heightScale
                var ex = a * ct - b * st
                var ey = a * st + b * ct
                if bend > 1e-3 {
                    let radius = 1 / bend
                    let phi = ex * bend
                    (ex, ey) = ((radius + ey) * sin(phi), (radius + ey) * cos(phi) - radius + happy * 0.05)
                }
                let spot = surface.place(from: centre, offset: SIMD2(ex * cr - ey * sr, ex * sr + ey * cr))
                let lifted = SIMD3(spot.x, spot.y, surface.height(spot.x, spot.y) + SolidTuning.eyeLift)
                let turned = rotation * lifted
                projected.append(SIMD2(turned.x, turned.y))
                leastFacing = min(leastFacing, (facingRow * surface.normal(spot.x, spot.y)).sum())
            }
            return projected
        }
        let fade = min(1, max(0, leastFacing / SolidTuning.nearLimb))
        let opacity = fade * fade * (3 - 2 * fade)
        guard opacity > 0 else { return .hidden }
        return SolidEyePair(outlines: outlines, opacity: opacity, nearEdge: leastFacing < SolidTuning.edgeClip)
    }
}
