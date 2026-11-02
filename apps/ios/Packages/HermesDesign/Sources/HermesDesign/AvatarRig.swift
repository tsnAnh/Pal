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

    init(
        viewBox: CGSize,
        clipsToViewBox: Bool,
        body: [AvatarDrawing.Element],
        eyes: Eyes,
        dots: [AvatarDrawing.Element] = [],
        bounds: CGRect? = nil
    ) {
        self.viewBox = viewBox
        self.clipsToViewBox = clipsToViewBox
        self.body = body
        self.eyes = eyes
        self.dots = dots
        let box = bounds ?? Self.bounds(of: body)
        pivot = CGPoint(x: box.midX, y: box.midY)
        span = (box.width + box.height) / 2
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

    func eyePaths(_ pose: AvatarPose) -> [Path] {
        let placements = zip(eyes.rest, eyes.facing).map { $0.blended(to: $1, pose.front) }
        guard !placements.isEmpty else { return [] }
        let mid = CGPoint(
            x: placements.map(\.centre.x).reduce(0, +) / Double(placements.count),
            y: placements.map(\.centre.y).reduce(0, +) / Double(placements.count)
        )
        let roll = pose.eyeRoll * Double.pi / 180
        let shape = eyeShape(pose)
        let travel = eyes.travel ?? span
        return placements.map { placement in
            let dx = (placement.centre.x - mid.x) * pose.eyeSpread
            let dy = (placement.centre.y - mid.y) * pose.eyeSpread
            let centre = CGPoint(
                x: mid.x + dx * cos(roll) - dy * sin(roll) + pose.eyeX * travel,
                y: mid.y + dx * sin(roll) + dy * cos(roll) + pose.eyeY * travel
            )
            let moved = EyePlacement(centre: centre, angle: placement.angle + roll, scale: placement.scale * pose.eyeScale)
            return shape.applying(moved.transform)
        }
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
        return Path(roundedRect: rect, cornerRadius: min(width, shownHeight) / 2)
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
