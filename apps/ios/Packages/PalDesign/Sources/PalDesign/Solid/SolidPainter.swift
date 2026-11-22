import CoreGraphics
import PalDiagnostics
import SwiftUI

struct SolidCanvas: View {
    let solid: AvatarSolid
    let pose: AvatarPose
    let size: CGFloat
    let look: AvatarLook
    let outline: AvatarOutline?
    let reduceMotion: Bool

    var body: some View {
        let inset = (size * 0.3).rounded()
        let side = size + 2 * inset
        let solid = solid.detailed(for: size)
        return Canvas { context, _ in
            PalPerf.interval("avatar.canvas.draw") {
                SolidPainter(solid: solid, size: size, inset: inset, outline: outline)
                    .paint(
                        SolidPose.resolve(pose: pose, look: look, restTilt: solid.restTilt, restTurn: solid.restTurn, reduceMotion: reduceMotion),
                        in: &context
                    )
            }
        }
        .frame(width: side, height: side)
        .frame(width: size, height: size)
    }
}

struct SolidPainter {
    let solid: AvatarSolid
    let size: CGFloat
    let inset: CGFloat
    let outline: AvatarOutline?

    private var scale: CGFloat { size / max(solid.rig.viewBox.width, solid.rig.viewBox.height) }

    func paint(_ pose: SolidPose, in context: inout GraphicsContext) {
        let placement = solid.placement(size: size, inset: inset)
        let pivot = solid.rig.pivot.applying(placement)
        let travel = solid.rig.span * scale
        context.translateBy(x: pivot.x + pose.bodyX * travel, y: pivot.y + pose.bodyY * travel)
        context.scaleBy(x: pose.bodyScaleX, y: pose.bodyScaleY)
        context.translateBy(x: -pivot.x, y: -pivot.y)
        let frame = SolidFrame.make(solid: solid, pose: pose, projection: solid.projection(size: size, inset: inset))
        if pose.opacity < 1 {
            context.opacity = pose.opacity
            context.drawLayer { layer in paintFigure(frame, pose, placement, in: &layer) }
        } else {
            paintFigure(frame, pose, placement, in: &context)
        }
    }

    private func paintFigure(_ frame: SolidFrame, _ pose: SolidPose, _ placement: CGAffineTransform, in context: inout GraphicsContext) {
        if let outline { paintOutline(outline, frame, in: &context) }
        if let body = solid.bodyFill {
            context.fill(frame.silhouette, with: .color(body.swiftUIColor))
        }
        paintEyes(frame, in: &context)
        for (index, dot) in solid.rig.dots.enumerated() where index < 3 && pose.dots[index] > 0 {
            guard let fill = dot.fill else { continue }
            context.fill(dot.path.applying(placement), with: .color(fill.swiftUIColor.opacity(pose.dots[index] * dot.opacity)))
        }
    }

    private func paintEyes(_ frame: SolidFrame, in context: inout GraphicsContext) {
        let ink = GraphicsContext.Shading.color(solid.eyeFill.swiftUIColor.opacity(frame.eyeOpacity))
        guard frame.eyesNearEdge else {
            for eye in frame.eyes { context.fill(eye, with: ink) }
            return
        }
        context.drawLayer { layer in
            layer.clipToLayer { mask in mask.fill(frame.silhouette, with: .color(.black)) }
            for eye in frame.eyes { layer.fill(eye, with: ink) }
        }
    }

    private func paintOutline(_ outline: AvatarOutline, _ frame: SolidFrame, in context: inout GraphicsContext) {
        let edge = frame.boundary()
        let style = { (width: CGFloat) in StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round) }
        context.drawLayer { layer in
            layer.stroke(edge, with: .color(outline.color), style: style(2 * (outline.gap + outline.thickness)))
            layer.fill(frame.silhouette, with: .color(outline.color))
            layer.blendMode = .destinationOut
            layer.stroke(edge, with: .color(.black), style: style(2 * outline.gap))
            layer.fill(frame.silhouette, with: .color(.black))
        }
    }
}
