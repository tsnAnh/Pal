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

private let shapes = BlobKind.allCases.map { "blobatar:k7q2m9x0:\($0.rawValue)" } + ClassicShape.allCases.map(\.rawValue)
private let directions: [(Double, Double)] = [(1, 0), (-1, 0), (0, 1), (0, -1), (0.7, 0.7), (-0.7, 0.7), (0.7, -0.7), (-0.7, -0.7)]

@Suite("Pointer look")
struct AvatarPointerLookTests {
    @Test("no hover leaves the pose and eyes untouched", arguments: shapes)
    func idleIsIdentity(shape: String) throws {
        let rig = try rig(shape)
        let pose = AvatarPose.rest
        #expect(rig.posed(pose, look: .zero, reduceMotion: false) == pose)
        #expect(rig.eyePaths(pose, look: .zero).map(\.boundingRect) == rig.eyePaths(pose).map(\.boundingRect))
    }

    @Test("pointer at the centre straightens the figure completely", arguments: shapes)
    func centreIsUpright(shape: String) throws {
        let rig = try rig(shape)
        let posed = rig.posed(.rest, look: AvatarLook(amount: 1, x: 0, y: 0), reduceMotion: false)
        #expect(abs(posed.bodyRotation + rig.restTilt) < 1e-9)
        #expect(abs(posed.eyeRoll - rig.restTilt) < 1e-9)
        #expect(posed.front == 1)
        let eyes = rig.eyePaths(posed, look: AvatarLook(amount: 1, x: 0, y: 0)).map(\.boundingRect)
        let facing = rig.eyePaths(posed).map(\.boundingRect)
        #expect(eyes == facing)
    }

    @Test("pointer to the side leans the head toward it", arguments: shapes)
    func leansTowardPointer(shape: String) throws {
        let rig = try rig(shape)
        let right = rig.posed(.rest, look: AvatarLook(amount: 1, x: 1, y: 0), reduceMotion: false).bodyRotation
        let left = rig.posed(.rest, look: AvatarLook(amount: 1, x: -1, y: 0), reduceMotion: false).bodyRotation
        #expect(right > left)
    }

    @Test("reduce motion keeps the figure still", arguments: shapes)
    func reducedMotionDoesNotRotate(shape: String) throws {
        let rig = try rig(shape)
        let posed = rig.posed(.rest, look: AvatarLook(amount: 1, x: 1, y: 0), reduceMotion: true)
        #expect(posed == .rest)
    }

    @Test("eyes follow the pointer and never leave the body", arguments: shapes)
    func eyesStayOnBody(shape: String) throws {
        let rig = try rig(shape)
        for direction in directions {
            let look = AvatarLook(amount: 1, x: direction.0, y: direction.1)
            let posed = rig.posed(.rest, look: look, reduceMotion: false)
            let centred = rig.eyePaths(posed, look: AvatarLook(amount: 1, x: 0, y: 0))
            let shifted = rig.eyePaths(posed, look: look)
            #expect(shifted.count == centred.count)
            #expect(shifted.allSatisfy { !$0.isEmpty })
            for eye in shifted {
                let middle = CGPoint(x: eye.boundingRect.midX, y: eye.boundingRect.midY)
                #expect(rig.surface.clearance(at: middle) > 0, "\(shape) \(direction)")
            }
        }
    }

    @Test("eyes move toward the pointer", arguments: shapes)
    func eyesMove(shape: String) throws {
        let rig = try rig(shape)
        let right = AvatarLook(amount: 1, x: 1, y: 0)
        let posed = rig.posed(.rest, look: right, reduceMotion: false)
        let still = rig.eyePaths(posed, look: AvatarLook(amount: 1, x: 0, y: 0)).map(\.boundingRect.midX).reduce(0, +)
        let moved = rig.eyePaths(posed, look: right).map(\.boundingRect.midX)
        #expect(moved.reduce(0, +) > still)
    }

    @Test("hover animates smoothly between idle and engaged")
    func animatableDataInterpolates() {
        var look = AvatarLook(amount: 1, x: 0.5, y: -0.5)
        look.scale(by: 0.5)
        #expect(look == AvatarLook(amount: 0.5, x: 0.25, y: -0.25))
        #expect(AvatarLook.toward(CGPoint(x: 50, y: 50), size: 100, reach: 0) == AvatarLook(amount: 1, x: 0, y: 0))
    }
}
