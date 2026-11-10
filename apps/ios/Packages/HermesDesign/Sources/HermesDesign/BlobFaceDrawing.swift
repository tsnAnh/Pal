import CoreGraphics
import SwiftUI

enum BlobFaceDrawing {
    private static let bodyRounding = 26.0
    private static let pill = (width: 14.2, height: 33.0, gap: 43.0, slant: -20.0, twist: -3.5, shiftX: 18.0, shiftY: -18.0, stagger: 8.0, reach: 11.0)
    private static let figure = CGAffineTransform.svgList([
        .svgRotate(-14, aroundX: 50, y: 50),
        .svgTranslate(50, 50),
        .svgScale(0.77),
        .svgTranslate(-50, -50),
    ])
    private static let figureScale = 0.77

    private struct Box {
        var minX: Double
        var maxX: Double
        var minY: Double
        var maxY: Double

        init?(pathData: String) {
            let values = JSCompat.numbers(in: pathData)
            let xs = values.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
            let ys = values.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
            self.minX = minX
            self.maxX = maxX
            self.minY = minY
            self.maxY = maxY
        }
    }

    static let viewBox = CGSize(width: 100, height: 100)

    static func make(_ blob: BlobAvatar) -> AvatarRig {
        let figure = BlobFigure(seed: blob.seed, kind: blob.kind)
        let head = blob.headFill(palette: figure.palette)
        let isCircle = (blob.kind ?? figure.silhouette) == .round

        let body = bodyElements(figure, circle: isCircle).map { path in
            AvatarDrawing.Element(
                path: path.applying(Self.figure),
                fill: head,
                stroke: .init(color: head, width: bodyRounding * figureScale, round: true)
            )
        }

        let rest = zip(pillCentres(figure), [pill.slant, pill.slant + pill.twist]).map { centre, slant in
            EyePlacement(CGAffineTransform.svgList([.svgTranslate(centre.x, centre.y), .svgRotate(slant)]).concatenating(Self.figure))
        }
        let eyeSize = CGSize(width: pill.width, height: pill.height)
        let bounds = AvatarRig.bounds(of: body)
        return AvatarRig(
            viewBox: viewBox,
            clipsToViewBox: true,
            body: body,
            eyes: .init(
                size: eyeSize,
                fill: head.eyeFill,
                rest: rest,
                facing: AvatarRig.facing(rest, size: eyeSize, bounds: bounds),
                mask: body
            ),
            bounds: bounds,
            restTilt: -14
        )
    }

    private static func bodyElements(_ figure: BlobFigure, circle: Bool) -> [Path] {
        if circle, let round = circleBody(figure.bodyPathData) { return [round] }
        let petals = figure.petals.map { petal -> Path in
            let cx = JSCompat.round2(petal.cx)
            let cy = JSCompat.round2(petal.cy)
            let r = JSCompat.round2(petal.r)
            return Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
        }
        return petals + figure.bodyPathData.map(SVGPathData.path)
    }

    private static func circleBody(_ pathData: [String]) -> Path? {
        let values = pathData.flatMap { JSCompat.numbers(in: $0) }
        let xs = values.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let ys = values.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        guard xs.count >= 3, ys.count >= 3, let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max()
        else { return nil }
        func rounded(_ value: Double) -> Double { Double(JSCompat.toFixed2(value)) ?? value }
        let cx = rounded((minX + maxX) / 2)
        let cy = rounded((minY + maxY) / 2)
        let r = rounded((maxX - minX + maxY - minY) / 4)
        return Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
    }

    private static func pillCentres(_ figure: BlobFigure) -> [CGPoint] {
        let boxes = figure.eyes.compactMap { Box(pathData: $0.path) }.sorted { $0.minX < $1.minX }
        guard boxes.count >= 2 else { return [] }
        let left = boxes[0]
        let right = boxes[1]
        let midX = (left.minX + left.maxX + right.minX + right.maxX) / 4 + pill.shiftX
        let midY = (left.minY + left.maxY + right.minY + right.maxY) / 4 + pill.shiftY

        func centre(_ x: Double, _ y: Double, _ box: Box) -> CGPoint {
            CGPoint(
                x: min(box.maxX + pill.reach, max(box.minX - pill.reach, x)),
                y: min(box.maxY + pill.reach, max(box.minY - pill.reach, y))
            )
        }

        return [centre(midX - pill.gap / 2, midY + pill.stagger / 2, left), centre(midX + pill.gap / 2, midY - pill.stagger / 2, right)]
    }
}
