import CoreGraphics
import SwiftUI

enum SolidTuning {
    static let turn = 34.0
    static let restLook = (x: 0.55, y: 0.6)
    static let restEyeSlant = 25.0
    static let eyeReach = 1.1
    static let eye = (width: 0.25, height: 0.56, gap: 0.5, y: 0.0)
    static let eyeLift = 0.02
    static let nearLimb = 0.18
}

struct AvatarSolid {
    let geometry: SolidGeometry
    let rig: AvatarRig

    init(_ rig: AvatarRig) {
        self.init(geometry: SolidGeometry.shared(for: rig), rig: rig)
    }

    private init(geometry: SolidGeometry, rig: AvatarRig) {
        self.geometry = geometry
        self.rig = rig
    }

    var bodyFill: AvatarColor? { rig.bodyColor }
    var eyeFill: AvatarColor { rig.eyes.fill }
    var restTilt: Double { rig.restTilt }

    func toned(for scheme: ColorScheme) -> AvatarSolid {
        AvatarSolid(geometry: geometry, rig: rig.toned(for: scheme))
    }

    func eyeInked(_ ink: AvatarColor) -> AvatarSolid {
        var rig = rig
        rig.eyes.fill = ink
        return AvatarSolid(geometry: geometry, rig: rig)
    }

    func placement(size: CGFloat, inset: CGFloat) -> CGAffineTransform {
        rig.placement(size: size, inset: inset)
    }

    func projection(size: CGFloat, inset: CGFloat) -> SolidProjection {
        let origin = geometry.centre.applying(placement(size: size, inset: inset))
        let scale = size / max(rig.viewBox.width, rig.viewBox.height)
        return SolidProjection(origin: origin, unit: geometry.radius * scale)
    }
}

struct SolidProjection {
    var origin: CGPoint
    var unit: Double

    func point(_ p: SIMD2<Double>) -> CGPoint {
        CGPoint(x: origin.x + p.x * unit, y: origin.y - p.y * unit)
    }
}

extension AvatarRig {
    func placement(size: CGFloat, inset: CGFloat) -> CGAffineTransform {
        let scale = size / max(viewBox.width, viewBox.height)
        return CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(
            translationX: (size - viewBox.width * scale) / 2 + inset,
            y: (size - viewBox.height * scale) / 2 + inset
        ))
    }
}
