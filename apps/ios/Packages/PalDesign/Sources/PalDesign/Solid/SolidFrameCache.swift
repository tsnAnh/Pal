import PalDiagnostics

struct SolidFrameKey: Hashable, Sendable {
    let geometry: UInt64
    let originX: Double
    let originY: Double
    let unit: Double
    let yaw: Double
    let pitch: Double
    let roll: Double
    let eyes: SolidEyeKey

    init(geometry: SolidGeometry, pose: SolidPose, projection: SolidProjection) {
        self.geometry = geometry.identity
        originX = projection.origin.x
        originY = projection.origin.y
        unit = projection.unit
        yaw = pose.yaw
        pitch = pose.pitch
        roll = pose.roll
        eyes = SolidEyeKey(geometry: geometry, pose: pose)
    }
}

extension SolidFrame {
    static let cache = SolidCache<SolidFrameKey, SolidFrame>(capacity: 48, weightLimit: 120_000)

    static func make(solid: AvatarSolid, pose: SolidPose, projection: SolidProjection) -> SolidFrame {
        let key = SolidFrameKey(geometry: solid.geometry, pose: pose, projection: projection)
        return cache.value(for: key, weight: solid.geometry.triangles.count / 3) {
            PalPerf.event("avatar.solid.frame.build")
            return SolidFrame(solid: solid, pose: pose, projection: projection)
        }
    }
}
