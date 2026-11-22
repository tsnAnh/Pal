import CoreGraphics
import SwiftUI

enum SolidTuning {
    static let turn = 41.0
    static let restLook = (x: 0.7, y: 0.51)
    static let restEyeSlant = 11.0
    static let restTurns: [BlobKind: RestTurn] = [.heart: RestTurn(look: 0.12, tilt: 0)]
    static let eyeReach = 1.1
    static let eye = (width: 0.23, height: 0.53, gap: 0.54, y: 0.14)
    static let eyeLift = 0.02
    static let nearLimb = 0.18
    static let edgeClip = 0.5
}

struct AvatarSolid {
    let geometry: SolidGeometry
    let rig: AvatarRig

    static let eyeInk = AvatarColor(css: "#000000") ?? .primary
    static let blackEyesFromContrast = 3.0
    static let lightSchemeWhite = AvatarColor(css: "#c7c7cc") ?? .primary

    init(_ rig: AvatarRig) {
        var rig = rig
        if let body = rig.bodyColor {
            rig.eyes.fill = body.contrastWithBlack < Self.blackEyesFromContrast ? AvatarColor(css: AvatarColor.lightEyeFillCSS) ?? .primary : Self.eyeInk
        }
        self.init(geometry: SolidGeometry.shared(for: rig), rig: rig)
    }

    private init(geometry: SolidGeometry, rig: AvatarRig) {
        self.geometry = geometry
        self.rig = rig
    }

    func detailed(for size: CGFloat) -> AvatarSolid {
        let detail = SolidGeometry.Detail(size: size)
        guard detail != .standard else { return self }
        return AvatarSolid(geometry: SolidGeometry.shared(for: rig, detail: detail), rig: rig)
    }

    var bodyFill: AvatarColor? { rig.bodyColor }
    var eyeFill: AvatarColor { rig.eyes.fill }
    var restTilt: Double { rig.restTilt }
    var restTurn: RestTurn { rig.restTurn }


    func toned(for scheme: ColorScheme) -> AvatarSolid {
        guard scheme == .light, let body = bodyFill, body.isWhite else { return self }
        let gray = Self.lightSchemeWhite
        func grayed(_ element: AvatarDrawing.Element) -> AvatarDrawing.Element {
            var result = element
            result.fill = element.fill.map { $0.recolored(to: gray) }
            result.stroke = element.stroke.map { AvatarDrawing.Stroke(color: $0.color.recolored(to: gray), width: $0.width, round: $0.round) }
            return result
        }
        var rig = rig
        rig.body = rig.body.map(grayed)
        rig.dots = rig.dots.map(grayed)
        return AvatarSolid(geometry: geometry, rig: rig)
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
