import CoreGraphics
import SwiftUI
import Testing
@testable import PalDesign

private func rig(_ shape: String) throws -> AvatarRig {
    let spec = BotAvatarSpec(name: "Atlas", meta: BotAvatarMeta(shape: shape, color: "#3e8ef7", custom: true))
    guard case .rig(let rig) = AvatarContent(spec) else {
        Issue.record("\(shape) did not build a rig")
        throw CancellationError()
    }
    return rig
}

private let bodyShapes = BlobKind.allCases.map { "blobatar:k7q2m9x0:\($0.rawValue)" } + ClassicShape.allCases.map(\.rawValue)
private let everyShape = bodyShapes + (1...6).map { "sigil-\($0)" }
private let starArmShapes: Set = ["blobatar:k7q2m9x0:\(BlobKind.burst.rawValue)"]

private func eyes(_ rig: AvatarRig, _ pose: AvatarPose) -> [CGRect] {
    rig.eyePaths(pose).map(\.boundingRect).sorted { $0.midX < $1.midX }
}

private func surface(_ path: Path) -> EyeSurface {
    EyeSurface(mask: [AvatarDrawing.Element(path: path, fill: .primary, stroke: nil)])
}

private func pill(_ surface: EyeSurface, at centre: CGPoint) -> CGRect {
    let eye = Path(roundedRect: CGRect(x: centre.x - 5, y: centre.y - 12, width: 10, height: 24), cornerRadius: 5)
    return surface.project(eye, around: centre).boundingRect
}

private func points(of path: Path) -> [CGPoint] {
    var points: [CGPoint] = []
    path.forEach { element in
        switch element {
        case .move(let to), .line(let to): points.append(to)
        default: break
        }
    }
    return points
}

@Suite("Eyes painted on the body")
struct EyeSurfaceTests {
    @Test("an eye sliding toward the rim of a ball narrows, most on its far side")
    func ballCurves() {
        let ball = surface(Path(ellipseIn: CGRect(x: 0, y: 0, width: 100, height: 100)))
        let middle = pill(ball, at: CGPoint(x: 50, y: 50))
        let side = pill(ball, at: CGPoint(x: 80, y: 50))
        #expect(abs(middle.width - 10) < 0.2)
        #expect(side.width < middle.width * 0.85)
        #expect(side.maxX - 80 < (80 - side.minX) * 0.92)
    }

    @Test("a flat-sided body keeps eyes flat where a ball would curve them")
    func shapeDecidesTheCurve() {
        let ball = surface(Path(ellipseIn: CGRect(x: 0, y: 0, width: 100, height: 100)))
        let slab = surface(Path(roundedRect: CGRect(x: -100, y: 0, width: 300, height: 100), cornerRadius: 50))
        let onBall = pill(ball, at: CGPoint(x: 80, y: 50))
        let onSlab = pill(slab, at: CGPoint(x: 80, y: 50))
        #expect(onSlab.width > onBall.width * 1.2)
        #expect(abs(onSlab.width - 10) < 0.2)
    }

    @Test("resting eyes off the centre are already foreshortened", arguments: ["blobatar:k7q2m9x0:round", "circle"])
    func restCurves(shape: String) throws {
        let rig = try rig(shape)
        let shown = rig.eyePaths(.rest).map(\.boundingRect)
        let size = rig.eyes.size
        let painted = Path(roundedRect: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height), cornerRadius: min(size.width, size.height) / 2)
        let flat = rig.eyes.rest.map { painted.applying($0.transform).boundingRect }
        try #require(shown.count == flat.count)
        let shrink = zip(shown, flat).map { ($0.width * $0.height) / ($1.width * $1.height) }
        #expect(shrink.allSatisfy { $0 < 0.995 })
    }

    @Test("painted eye points never leave the body", arguments: everyShape)
    func staysOnBody(shape: String) throws {
        let rig = try rig(shape)
        let looks: [AvatarPose] = [.rest, .facing] + [-0.5, -0.3, -0.15, 0.15, 0.3, 0.5].flatMap { look in
            [AvatarPose.facing.with { $0.eyeX = look }, AvatarPose.facing.with { $0.eyeY = look }]
        }
        for pose in looks {
            for eye in rig.eyePaths(pose) {
                for point in points(of: eye) {
                    let onBody = rig.eyes.mask.contains { part in
                        let reach = (part.stroke?.width ?? 0) + rig.span * 0.03
                        return part.path.contains(point) || part.path.strokedPath(StrokeStyle(lineWidth: reach, lineJoin: .round)).contains(point)
                    }
                    #expect(onBody, "\(pose.eyeX),\(pose.eyeY) \(point)")
                }
            }
        }
    }

    @Test("looking right moves the pair right and squeezes the leading eye", arguments: everyShape.filter { !starArmShapes.contains($0) })
    func lookRight(shape: String) throws {
        let rig = try rig(shape)
        let rest = eyes(rig, .facing)
        let look = eyes(rig, .facing.with { $0.eyeX = 0.2 })
        try #require(look.count == rest.count && !rest.isEmpty)
        #expect(look.map(\.midX).reduce(0, +) > rest.map(\.midX).reduce(0, +))
        let leading = try #require(look.last)
        let restLeading = try #require(rest.last)
        #expect(leading.width < restLeading.width)
    }

    @Test("a small glance moves the eyes as far as it always has", arguments: everyShape)
    func glanceKeepsChoreography(shape: String) throws {
        let rig = try rig(shape)
        let glance = 0.05
        let travel = rig.eyes.travel ?? rig.span
        let rest = eyes(rig, .facing)
        let moved = eyes(rig, .facing.with { $0.eyeX = glance })
        let shift = (moved.map(\.midX).reduce(0, +) - rest.map(\.midX).reduce(0, +)) / Double(rest.count)
        #expect(shift > glance * travel * 0.6)
        #expect(shift < glance * travel * 1.05)
    }

    @Test("eyes are off the body whenever motion treats them as hidden", arguments: bodyShapes)
    func hiddenOffBody(shape: String) throws {
        let rig = try rig(shape)
        for clip in LoadingClips.all {
            for t in stride(from: 0.0, through: clip.duration, by: 1.0 / 120) {
                let pose = clip.track.pose(at: t)
                if abs(pose.eyeX) >= 0.75 || abs(pose.eyeY) >= 0.75 {
                    let gone = rig.eyePaths(pose).allSatisfy { $0.isEmpty }
                    #expect(gone, "\(clip.name) t \(t)")
                }
            }
        }
    }

    @Test("happy eyes wrap too")
    func happyEyes() throws {
        let rig = try rig("blobatar:k7q2m9x0:round")
        let happy = AvatarPose.facing.with { $0.eyeHappy = 1 }
        let rest = eyes(rig, happy)
        let look = eyes(rig, happy.with { $0.eyeX = 0.25 })
        let leading = try #require(look.last)
        let restLeading = try #require(rest.last)
        #expect(leading.width < restLeading.width * 0.95)
    }
}
