import CoreGraphics
import SwiftUI
import Testing
@testable import PalDesign

private let size: CGFloat = 80
private let inset: CGFloat = 24

private func make(_ solid: AvatarSolid, _ pose: SolidPose) -> SolidFrame {
    SolidFrame.make(solid: solid, pose: pose, projection: solid.projection(size: size, inset: inset))
}

@Suite("Solid frame caches", .serialized)
struct SolidFrameCacheTests {
    private let avatar = solid("blobatar:k7q2m9x0:cloud", color: "#41a3f2")

    private func key(_ pose: SolidPose, size frameSize: CGFloat = size, of body: AvatarSolid? = nil) -> SolidFrameKey {
        let body = body ?? avatar
        return SolidFrameKey(geometry: body.geometry, pose: pose, projection: body.projection(size: frameSize, inset: inset))
    }

    @Test("a cache builds a value once, returns it on every later read and counts both")
    func cacheBuildsOnce() {
        let cache = SolidCache<Int, String>(capacity: 4)
        var builds = 0
        let first = cache.value(for: 1) { builds += 1; return "one" }
        let second = cache.value(for: 1) { builds += 1; return "other" }
        #expect(first == "one")
        #expect(second == "one")
        #expect(builds == 1)
        #expect(cache.statistics == .init(hits: 1, misses: 1))
    }

    @Test("a cache evicts the least recently read entry once it passes its count or weight")
    func cacheEvictsOldest() {
        let cache = SolidCache<Int, Int>(capacity: 2, weightLimit: 10)
        _ = cache.value(for: 1) { 1 }
        _ = cache.value(for: 2) { 2 }
        _ = cache.value(for: 1) { 0 }
        _ = cache.value(for: 3) { 3 }
        #expect(cache.count == 2)
        #expect(cache.value(for: 1) { -1 } == 1)
        #expect(cache.value(for: 2) { -2 } == -2)
        _ = cache.value(for: 4, weight: 10) { 4 }
        #expect(cache.count == 1)
    }

    @Test("drawing the same pose twice returns the same shapes")
    func samePoseSameShapes() {
        let pose = SolidPose(yaw: 23, pitch: 7)
        let first = make(avatar, pose)
        let second = make(avatar, pose)
        #expect(key(pose) == key(SolidPose(yaw: 23, pitch: 7)))
        #expect(first.silhouette == second.silhouette)
        #expect(first.eyes == second.eyes)
        #expect(first.eyeOpacity == second.eyeOpacity)
    }

    @Test("a body bob, squash or fade moves the canvas, not the mesh, so the frame is reused")
    func bodyMotionReusesFrame() {
        let moved = SolidPose(yaw: 23, bodyX: 0.1, bodyY: -0.2, bodyScaleX: 1.1, bodyScaleY: 0.9, opacity: 0.5)
        #expect(key(moved) == key(SolidPose(yaw: 23)))
        #expect(make(avatar, moved).silhouette == SolidFrame(solid: avatar, pose: moved, projection: avatar.projection(size: size, inset: inset)).silhouette)
    }

    @Test("a turn, a different size or a different solid each need their own frame")
    func differentInputsMiss() {
        let base = key(SolidPose(yaw: 23))
        #expect(key(SolidPose(yaw: 24)) != base)
        #expect(key(SolidPose(yaw: 23), size: size + 1) != base)
        #expect(key(SolidPose(yaw: 23), of: solid("blobatar:k7q2m9x0:boxy")) != base)
    }

    @Test("the cache stays inside its bound however many poses stream through")
    func bounded() {
        for index in 0..<200 { _ = make(avatar, SolidPose(yaw: 100 + Double(index) * 0.37)) }
        #expect(SolidFrame.cache.count <= 48)
    }

    @Test("a turn that leaves the eye fields alone reuses the eye placement, a blink does not")
    func eyePlacementReuse() {
        let geometry = avatar.geometry
        let resting = SolidEyeKey(geometry: geometry, pose: SolidPose(yaw: 23))
        #expect(SolidEyeKey(geometry: geometry, pose: SolidPose(yaw: 26, pitch: 2)) == resting)
        #expect(SolidEyeKey(geometry: geometry, pose: SolidPose(yaw: 26, eyeOpen: 0.3)) != resting)
    }

    @Test("a body's mesh is shared by every copy of it and by its tinted variants")
    func geometryShared() {
        let first = solid("blobatar:k7q2m9x0:cloud", color: "#41a3f2")
        let second = solid("blobatar:k7q2m9x0:cloud", color: "#41a3f2")
        #expect(first.geometry.identity == second.geometry.identity)
        #expect(first.eyeInked(.primary).geometry.identity == first.geometry.identity)
        #expect(first.toned(for: .light).geometry.identity == first.geometry.identity)
    }

    @Test("the fine mesh for a large avatar is resolved once and is finer than the standard one")
    func fineMeshResolvedOnce() {
        let fine = avatar.detailed(for: 201)
        #expect(fine.geometry.triangles.count > avatar.geometry.triangles.count * 4)
        #expect(avatar.detailed(for: 201).geometry.identity == fine.geometry.identity)
        #expect(solid("blobatar:k7q2m9x0:cloud", color: "#41a3f2").detailed(for: 201).geometry.identity == fine.geometry.identity)
        #expect(avatar.detailed(for: 199).geometry.identity == avatar.geometry.identity)
    }
}
