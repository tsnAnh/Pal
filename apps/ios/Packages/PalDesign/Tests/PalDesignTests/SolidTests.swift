import CoreGraphics
import SwiftUI
import Testing
@testable import PalDesign

private let size: CGFloat = 100
private let inset: CGFloat = 0
private let straight = SolidPose()

private func frame(_ solid: AvatarSolid, _ pose: SolidPose) -> SolidFrame {
    SolidFrame(solid: solid, pose: pose, projection: solid.projection(size: size, inset: inset))
}

private func resolved(
    _ solid: AvatarSolid, _ pose: AvatarPose = .rest, look: AvatarLook = .zero, reduceMotion: Bool = false
) -> SolidPose {
    SolidPose.resolve(pose: pose, look: look, restTilt: solid.restTilt, reduceMotion: reduceMotion)
}

private func eyeCentre(_ frame: SolidFrame) -> CGPoint {
    let centres = frame.eyes.map { centroid(of: $0.path) }
    return CGPoint(x: centres.map(\.x).reduce(0, +) / Double(centres.count), y: centres.map(\.y).reduce(0, +) / Double(centres.count))
}

@Suite("Solid body")
struct SolidBodyTests {
    @Test("a round solid at the identity pose draws a seamless disc of the avatar's footprint")
    func roundFootprint() throws {
        let circle = solid("circle")
        let mesh = frame(circle, straight)
        let raster = Raster(filling: mesh.silhouette)
        let scale = size / max(circle.rig.viewBox.width, circle.rig.viewBox.height)
        let radius = (16.2 * 0.72 + 13 * 0.72 / 2) * scale
        let origin = circle.projection(size: size, inset: inset).origin
        #expect(abs(raster.area - Double.pi * radius * radius) / (Double.pi * radius * radius) < 0.02)
        let bounds = mesh.silhouette.boundingRect
        #expect(abs(bounds.width / 2 - radius) / radius < 0.02)
        #expect(abs(bounds.midX - origin.x) < 1 && abs(bounds.midY - origin.y) < 1)
        for y in 0..<raster.side {
            for x in 0..<raster.side where hypot(Double(x) + 0.5 - origin.x, Double(y) + 0.5 - origin.y) < radius * 0.93 {
                #expect(raster[x, y] >= 250, "hole at \(x),\(y)")
            }
        }
    }

    @Test("at the rest tilt the solid fills the same silhouette as the flat avatar", arguments: SolidTestShapes.all)
    func matchesFlatSilhouette(shape: String) {
        let avatar = solid(shape)
        let pose = SolidPose(roll: avatar.restTilt)
        let drawn = Raster(filling: frame(avatar, pose).silhouette)
        let flat = flatBody(avatar.rig, size: size, inset: inset)
        #expect(drawn.overlap(with: flat) > 0.93, "\(shape) overlaps \(drawn.overlap(with: flat))")
    }

    @Test("a quarter turn shows the body's depth, which is its inscribed diameter")
    func turnsAsAWhole() {
        let pill = solid("pill")
        let unit = pill.projection(size: size, inset: inset).unit
        let front = frame(pill, straight).silhouette.boundingRect
        let sideways = frame(pill, SolidPose(yaw: 90)).silhouette.boundingRect
        #expect(abs(sideways.width - 2 * unit) / (2 * unit) < 0.03)
        #expect(sideways.width < front.width * 0.9)
        #expect(abs(sideways.height - front.height) / front.height < 0.05)
    }

    @Test("the outline ring hugs the silhouette it surrounds")
    func boundaryMatchesSilhouette() {
        let hex = solid("hexagon")
        let mesh = frame(hex, SolidPose(yaw: 25, pitch: 15, roll: -14))
        let bounds = mesh.silhouette.boundingRect
        let edge = mesh.boundary().boundingRect
        #expect(abs(edge.minX - bounds.minX) < 0.01 && abs(edge.maxX - bounds.maxX) < 0.01)
        #expect(abs(edge.minY - bounds.minY) < 0.01 && abs(edge.maxY - bounds.maxY) < 0.01)
    }

    @Test("blob and classic bodies keep their fill; toning for light recolours a white body")
    func toning() throws {
        let white = solid("round", color: "#ffffff")
        #expect(white.toned(for: .dark).bodyFill == white.bodyFill)
        #expect(white.toned(for: .light).bodyFill != white.bodyFill)
    }
}

@Suite("Solid pose")
struct SolidPoseTests {
    private let avatar = solid("circle")

    @Test("resting turns the face up and to the right with tilted slanted eyes")
    func rest() {
        let pose = resolved(avatar)
        #expect(abs(pose.yaw - 0.55 * 34) < 1e-9)
        #expect(abs(pose.pitch - 0.6 * 34) < 1e-9)
        #expect(pose.roll == avatar.restTilt)
        #expect(abs(pose.eyeRoll - 25) < 1e-9)
    }

    @Test("facing the viewer has no turn, no tilt and no slant")
    func facing() {
        let pose = resolved(avatar, .facing)
        #expect(pose == SolidPose())
    }

    @Test("pointing at the avatar straightens it completely")
    func hoverCentre() {
        let pose = resolved(avatar, look: AvatarLook(amount: 1, x: 0, y: 0))
        #expect(pose == SolidPose())
    }

    @Test("looking right yaws right, looking up pitches up")
    func hoverDirections() {
        let right = resolved(avatar, look: AvatarLook(amount: 1, x: 1, y: 0))
        let up = resolved(avatar, look: AvatarLook(amount: 1, x: 0, y: -1))
        #expect(abs(right.yaw - 34) < 1e-9 && abs(right.pitch) < 1e-9)
        #expect(abs(up.pitch - 34) < 1e-9 && abs(up.yaw) < 1e-9)
    }

    @Test("the 2D eye offsets of the old clips become body turns")
    func eyeOffsetsTurnTheBody() {
        let looking = resolved(avatar, AvatarPose.facing.with { $0.eyeX = 0.9; $0.eyeY = 0.2 })
        #expect(looking.yaw > 80 && looking.yaw < 85)
        #expect(looking.pitch < 0)
        let unclamped = resolved(avatar, AvatarPose.facing.with { $0.eyeX = 5 })
        #expect(abs(unclamped.yaw - 90) < 1e-9)
    }

    @Test("reduce motion ignores the pointer")
    func reducedMotion() {
        let look = AvatarLook(amount: 1, x: 1, y: -1)
        #expect(resolved(avatar, look: look, reduceMotion: true) == resolved(avatar))
    }

    @Test("the other pose fields travel through untouched")
    func carriesThrough() {
        let source = AvatarPose.facing.with {
            $0.eyeScale = 0.8; $0.eyeSpread = 1.1; $0.eyeDot = 0.4; $0.eyeHappy = 0.3; $0.eyeOpen = 0.5
            $0.bodyX = 0.02; $0.bodyY = -0.1; $0.bodyScaleX = 1.1; $0.bodyScaleY = 0.9; $0.opacity = 0.7
            $0.bodyRotation = 5; $0.dots = SIMD3(0.2, 0.4, 0.6); $0.yaw = 12; $0.pitch = -8
        }
        let pose = resolved(avatar, source)
        #expect(pose.eyeScale == 0.8 && pose.eyeSpread == 1.1 && pose.eyeDot == 0.4 && pose.eyeHappy == 0.3 && pose.eyeOpen == 0.5)
        #expect(pose.bodyX == 0.02 && pose.bodyY == -0.1 && pose.bodyScaleX == 1.1 && pose.bodyScaleY == 0.9)
        #expect(pose.opacity == 0.7 && pose.dots == SIMD3(0.2, 0.4, 0.6) && pose.roll == 5)
        #expect(pose.yaw == 12 && pose.pitch == -8)
    }
}

@Suite("Solid eyes")
struct SolidEyeTests {
    private let shapes = ["circle", "blobatar:k7q2m9x0:round", "pill", "cloud"]

    @Test("resting eyes sit up and right of centre, both on the body", arguments: ["circle", "blobatar:k7q2m9x0:round", "pill"])
    func restingEyes(shape: String) {
        let avatar = solid(shape)
        let mesh = frame(avatar, resolved(avatar))
        let origin = avatar.projection(size: size, inset: inset).origin
        let raster = Raster(filling: mesh.silhouette)
        #expect(mesh.eyes.count == 2)
        let middle = eyeCentre(mesh)
        #expect(middle.x > origin.x + 2 && middle.y < origin.y - 2)
        for eye in mesh.eyes { #expect(raster.coverage(at: centroid(of: eye.path)) == 1) }
    }

    @Test("pointing at the centre centres both eyes and stands them upright", arguments: ["circle", "blobatar:k7q2m9x0:round", "pill"])
    func centredEyes(shape: String) {
        let avatar = solid(shape)
        let mesh = frame(avatar, resolved(avatar, look: AvatarLook(amount: 1, x: 0, y: 0)))
        let origin = avatar.projection(size: size, inset: inset).origin
        let middle = eyeCentre(mesh)
        #expect(abs(middle.x - origin.x) < 0.5 && abs(middle.y - origin.y) < 0.5)
        for eye in mesh.eyes { #expect(verticalTilt(of: eye.path) < 2, "\(shape) tilt \(verticalTilt(of: eye.path))") }
        let ys = mesh.eyes.map { centroid(of: $0.path).y }
        #expect(abs(ys[0] - ys[1]) < 0.5)
    }

    @Test("the eyes follow the pointer by turning the body")
    func eyesFollow() {
        let avatar = solid("circle")
        let centre = eyeCentre(frame(avatar, resolved(avatar, look: AvatarLook(amount: 1, x: 0, y: 0))))
        let right = eyeCentre(frame(avatar, resolved(avatar, look: AvatarLook(amount: 1, x: 1, y: 0))))
        let up = eyeCentre(frame(avatar, resolved(avatar, look: AvatarLook(amount: 1, x: 0, y: -1))))
        let left = eyeCentre(frame(avatar, resolved(avatar, look: AvatarLook(amount: 1, x: -1, y: 0))))
        #expect(right.x > centre.x + 5 && left.x < centre.x - 5)
        #expect(up.y < centre.y - 5)
    }

    @Test("a body turned away shows no eyes", arguments: [150.0, 180, -170])
    func turnedAway(yaw: Double) {
        let avatar = solid("circle")
        #expect(frame(avatar, SolidPose(yaw: yaw)).eyes.isEmpty)
        #expect(frame(avatar, SolidPose(pitch: yaw)).eyes.isEmpty)
    }

    @Test("an eye rolling over the limb is cut off and stays on the body", arguments: [55.0, 62, 70, 76])
    func limbEyesStayInside(yaw: Double) {
        let avatar = solid("circle")
        let mesh = frame(avatar, SolidPose(yaw: yaw))
        let raster = Raster(filling: mesh.silhouette)
        #expect(mesh.eyes.count >= 1)
        let origin = avatar.projection(size: size, inset: inset).origin
        let radius = mesh.silhouette.boundingRect.width / 2
        let slack = 0.03 * avatar.projection(size: size, inset: inset).unit
        for eye in mesh.eyes {
            for point in vertices(of: eye.path) {
                #expect(hypot(point.x - origin.x, point.y - origin.y) <= radius + slack, "eye leaves the body at yaw \(yaw)")
                #expect(raster.coverage(at: point) > 0 || hypot(point.x - origin.x, point.y - origin.y) > radius - 1)
            }
        }
    }

    @Test("happy and dot eyes keep their shape on the surface")
    func morphs() {
        let avatar = solid("circle")
        let flat = frame(avatar, SolidPose(eyeDot: 1)).eyes
        for eye in flat {
            let bounds = eye.path.boundingRect
            #expect(abs(bounds.width - bounds.height) / bounds.width < 0.08)
        }
        let happy = frame(avatar, SolidPose(eyeHappy: 1)).eyes
        #expect(happy.count == 2)
        for eye in happy { #expect(eye.path.boundingRect.width > eye.path.boundingRect.height) }
    }

    @Test("every shape builds a mesh whose eyes land inside it", arguments: SolidTestShapes.all)
    func everyShape(shape: String) {
        let avatar = solid(shape)
        let mesh = frame(avatar, resolved(avatar))
        let raster = Raster(filling: mesh.silhouette)
        #expect(mesh.eyes.count == 2)
        for eye in mesh.eyes { #expect(raster.coverage(at: centroid(of: eye.path)) == 1, "\(shape)") }
        #expect(avatar.geometry.radius > 0 && avatar.geometry.surface.rim.allSatisfy { $0 > 0.5 })
    }
}

@Suite("Hover reach")
struct HoverReachTests {
    @Test("every avatar size follows the pointer, small rows included", arguments: [22.0, 25.3, 28, 43, 66, 72, 136, 160])
    func everySizeReaches(size: Double) {
        let reach = AvatarLook.defaultReach(size: CGFloat(size))
        #expect(reach >= 9)
        #expect(Double(reach) == (size * 0.4).rounded())
    }
}
