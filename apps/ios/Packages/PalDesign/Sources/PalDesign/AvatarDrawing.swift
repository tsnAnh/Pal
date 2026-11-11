import CoreGraphics
import SwiftUI

struct AvatarDrawing {
    struct Stroke {
        var color: AvatarColor
        var width: Double
        var round: Bool
    }

    struct Element {
        var path: Path
        var fill: AvatarColor?
        var stroke: Stroke?
        var opacity: Double = 1
    }

    var viewBox: CGSize
    var elements: [Element]
}

extension CGAffineTransform {
    static func svgTranslate(_ x: Double, _ y: Double) -> CGAffineTransform {
        CGAffineTransform(translationX: x, y: y)
    }

    static func svgScale(_ factor: Double) -> CGAffineTransform {
        CGAffineTransform(scaleX: factor, y: factor)
    }

    static func svgRotate(_ degrees: Double, aroundX x: Double = 0, y: Double = 0) -> CGAffineTransform {
        svgList([
            svgTranslate(x, y),
            CGAffineTransform(rotationAngle: degrees * Double.pi / 180),
            svgTranslate(-x, -y),
        ])
    }

    static func svgList(_ steps: [CGAffineTransform]) -> CGAffineTransform {
        steps.reversed().reduce(CGAffineTransform.identity) { combined, step in combined.concatenating(step) }
    }
}
