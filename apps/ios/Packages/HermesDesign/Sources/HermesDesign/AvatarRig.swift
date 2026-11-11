import CoreGraphics
import SwiftUI

struct EyePlacement: Equatable {
    var centre: CGPoint
    var angle: Double
    var scale: Double

    init(centre: CGPoint, angle: Double, scale: Double) {
        self.centre = centre
        self.angle = angle
        self.scale = scale
    }

    init(_ transform: CGAffineTransform) {
        centre = CGPoint(x: transform.tx, y: transform.ty)
        angle = atan2(transform.b, transform.a)
        scale = hypot(transform.a, transform.b)
    }

    var transform: CGAffineTransform {
        let cosine = scale * cos(angle)
        let sine = scale * sin(angle)
        return CGAffineTransform(a: cosine, b: sine, c: -sine, d: cosine, tx: centre.x, ty: centre.y)
    }

    func blended(to other: EyePlacement, _ amount: Double) -> EyePlacement {
        EyePlacement(
            centre: CGPoint(
                x: centre.x + (other.centre.x - centre.x) * amount,
                y: centre.y + (other.centre.y - centre.y) * amount
            ),
            angle: angle + (other.angle - angle) * amount,
            scale: scale + (other.scale - scale) * amount
        )
    }
}

struct AvatarRig {
    struct Eyes {
        var size: CGSize
        var fill: AvatarColor
        var rest: [EyePlacement]
        var facing: [EyePlacement]
        var mask: [AvatarDrawing.Element]
        var travel: Double?
    }

    var viewBox: CGSize
    var clipsToViewBox: Bool
    var body: [AvatarDrawing.Element]
    var eyes: Eyes
    var dots: [AvatarDrawing.Element] = []
    var pivot: CGPoint
    var span: Double
    var restTilt: Double
    let surface: EyeSurface

    init(
        viewBox: CGSize,
        clipsToViewBox: Bool,
        body: [AvatarDrawing.Element],
        eyes: Eyes,
        dots: [AvatarDrawing.Element] = [],
        bounds: CGRect? = nil,
        restTilt: Double = 0
    ) {
        self.viewBox = viewBox
        self.clipsToViewBox = clipsToViewBox
        self.body = body
        self.eyes = eyes
        self.dots = dots
        let box = bounds ?? Self.bounds(of: body)
        pivot = CGPoint(x: box.midX, y: box.midY)
        span = (box.width + box.height) / 2
        self.restTilt = restTilt
        surface = EyeSurface.shared(mask: eyes.mask)
    }

    static let facingHeight = 0.34
    static let facingSeparation = 0.30
    static let facingDrop = 0.01

    static func facing(_ rest: [EyePlacement], size: CGSize, bounds: CGRect) -> [EyePlacement] {
        let span = (bounds.width + bounds.height) / 2
        let scale = span * facingHeight / size.height
        let separation = span * facingSeparation
        let y = bounds.midY + span * facingDrop
        return rest.indices.map { index in
            let side = rest.count < 2 ? 0 : (Double(index) / Double(rest.count - 1) - 0.5)
            return EyePlacement(centre: CGPoint(x: bounds.midX + side * separation, y: y), angle: 0, scale: scale)
        }
    }

    static func bounds(of elements: [AvatarDrawing.Element]) -> CGRect {
        elements.reduce(CGRect.null) { box, element in
            let reach = (element.stroke?.width ?? 0) / 2
            return box.union(element.path.boundingRect.insetBy(dx: -reach, dy: -reach))
        }
    }

    func eyePaths(_ pose: AvatarPose, look: AvatarLook = .zero) -> [Path] {
        let placements = zip(eyes.rest, eyes.facing).map { $0.blended(to: $1, pose.front) }
        guard !placements.isEmpty else { return [] }
        let mid = Self.centroid(placements)
        let roll = pose.eyeRoll * Double.pi / 180
        let shape = eyeShape(pose)
        let travel = eyes.travel ?? span
        let cosRoll: Double = cos(roll)
        let sinRoll: Double = sin(roll)
        let spread: Double = pose.eyeSpread
        let offsetX: Double = pose.eyeX * travel
        let offsetY: Double = pose.eyeY * travel
        let centres: [CGPoint] = placements.map { (placement: EyePlacement) -> CGPoint in
            let dx: Double = (placement.centre.x - mid.x) * spread
            let dy: Double = (placement.centre.y - mid.y) * spread
            let rotatedX: Double = dx * cosRoll - dy * sinRoll
            let rotatedY: Double = dx * sinRoll + dy * cosRoll
            return CGPoint(x: mid.x + rotatedX + offsetX, y: mid.y + rotatedY + offsetY)
        }
        let gaze = gazeOffset(look, bodyRotation: pose.bodyRotation, centres: centres, clearance: eyeClearance(pose, placements))
        var paths: [Path] = []
        paths.reserveCapacity(placements.count)
        for (placement, base) in zip(placements, centres) {
            let centre = CGPoint(x: base.x + gaze.dx, y: base.y + gaze.dy)
            let moved = EyePlacement(centre: centre, angle: placement.angle + roll, scale: placement.scale * pose.eyeScale)
            paths.append(surface.project(shape.applying(moved.transform), around: centre))
        }
        return paths
    }

    private func eyeClearance(_ pose: AvatarPose, _ placements: [EyePlacement]) -> Double {
        let scale = placements.map(\.scale).max() ?? 1
        return eyes.size.height * scale * pose.eyeScale * 0.5
    }

    private func gazeOffset(_ look: AvatarLook, bodyRotation: Double, centres: [CGPoint], clearance: Double) -> CGVector {
        let strength = look.amount
        guard strength > 0, look.x != 0 || look.y != 0 else { return .zero }
        let turn = -bodyRotation * Double.pi / 180
        let reach = (eyes.travel ?? span) * Self.lookReach * strength
        let wanted = CGVector(
            dx: (look.x * cos(turn) - look.y * sin(turn)) * reach,
            dy: (look.x * sin(turn) + look.y * cos(turn)) * reach
        )
        let floor = min(clearance, centres.map { surface.clearance(at: $0) }.min() ?? clearance)
        func fits(_ fraction: Double) -> Bool {
            centres.allSatisfy {
                surface.clearance(at: CGPoint(x: $0.x + wanted.dx * fraction, y: $0.y + wanted.dy * fraction)) >= floor
            }
        }
        guard !fits(1) else { return wanted }
        var low = 0.0
        var high = 1.0
        for _ in 0..<10 {
            let middle = (low + high) / 2
            if fits(middle) { low = middle } else { high = middle }
        }
        return CGVector(dx: wanted.dx * low, dy: wanted.dy * low)
    }

    private static func centroid(_ placements: [EyePlacement]) -> CGPoint {
        let count = Double(placements.count)
        return CGPoint(
            x: placements.map(\.centre.x).reduce(0, +) / count,
            y: placements.map(\.centre.y).reduce(0, +) / count
        )
    }

    private func eyeShape(_ pose: AvatarPose) -> Path {
        let width = eyes.size.width
        let height = eyes.size.height
        if pose.eyeHappy >= 0.5 {
            let grow = 0.6 + 0.8 * (pose.eyeHappy - 0.5)
            return happyArc(width: width, height: height).applying(CGAffineTransform(scaleX: grow, y: grow))
        }
        let rounded = height + (width - height) * pose.eyeDot
        let squash = 1 - 1.3 * pose.eyeHappy
        let shownHeight = max(0.01, rounded * pose.eyeOpen * squash)
        let rect = CGRect(x: -width / 2, y: -shownHeight / 2, width: width, height: shownHeight)
        return Path(roundedRect: rect, cornerRadius: min(width, shownHeight) / 2, style: .circular)
    }

    private func happyArc(width: Double, height: Double) -> Path {
        let thickness = min(width, height) * 0.5
        let reach = max(height * 0.65, width * 1.3)
        let radius = (reach - thickness) / 2
        var arc = Path()
        let steps = 16
        for step in 0...steps {
            let angle = (160 + 220 * Double(step) / Double(steps)) * Double.pi / 180
            let point = CGPoint(x: radius * cos(angle), y: radius * sin(angle) + radius * 0.33)
            if step == 0 { arc.move(to: point) } else { arc.addLine(to: point) }
        }
        return arc.strokedPath(StrokeStyle(lineWidth: thickness, lineCap: .round, lineJoin: .round))
    }
}
