import CoreGraphics
import Foundation
import SwiftUI
@testable import PalDesign

enum SolidTestShapes {
    static let blobs = BlobKind.allCases.map { "blobatar:k7q2m9x0:\($0.rawValue)" }
    static let classics = ClassicShape.allCases.map(\.rawValue)
    static let all = blobs + classics
}

func shapeAvatar(_ shape: String, color: String = "#3e8ef7") -> ShapeAvatar {
    let spec = BotAvatarSpec(name: "Atlas", meta: BotAvatarMeta(shape: shape, color: color, custom: true))
    guard case .shape(let avatar) = spec else { fatalError("\(shape) is not a shape avatar") }
    return avatar
}

func flatRig(_ shape: String, color: String = "#3e8ef7") -> AvatarRig {
    AvatarContent.rig(shapeAvatar(shape, color: color))
}

func flatContent(_ spec: BotAvatarSpec) -> AvatarContent {
    guard case .shape(let avatar) = spec else { return AvatarContent(spec) }
    return .rig(AvatarContent.rig(avatar))
}

extension AvatarContent {
    var flatRig: AvatarRig? {
        switch self {
        case .rig(let rig): rig
        case .solid(let solid): solid.rig
        case .photo: nil
        }
    }
}

func solid(_ shape: String, color: String = "#3e8ef7") -> AvatarSolid {
    AvatarSolid(flatRig(shape, color: color))
}

let sideLength = 200

struct Raster {
    let side: Int
    var alpha: [UInt8]

    init(side: Int = sideLength, _ draw: (CGContext) -> Void) {
        self.side = side
        var bytes = [UInt8](repeating: 0, count: side * side)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            context.translateBy(x: 0, y: CGFloat(side))
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(gray: 1, alpha: 1)
            draw(context)
        }
        alpha = bytes
    }

    init(filling path: Path, side: Int = sideLength) {
        self.init(side: side) { context in
            context.addPath(path.cgPath)
            context.fillPath()
        }
    }

    subscript(x: Int, y: Int) -> UInt8 { alpha[y * side + x] }

    var area: Double { alpha.reduce(0) { $0 + Double($1) } / 255 }

    func coverage(at point: CGPoint) -> Double {
        let x = Int(point.x.rounded(.down))
        let y = Int(point.y.rounded(.down))
        guard x >= 0, y >= 0, x < side, y < side else { return 0 }
        return Double(self[x, y]) / 255
    }

    func overlap(with other: Raster) -> Double {
        var both = 0.0
        var either = 0.0
        for index in alpha.indices {
            let a = Double(alpha[index]) / 255
            let b = Double(other.alpha[index]) / 255
            both += min(a, b)
            either += max(a, b)
        }
        return either > 0 ? both / either : 0
    }
}

func flatBody(_ rig: AvatarRig, size: CGFloat, inset: CGFloat) -> Raster {
    let placement = rig.placement(size: size, inset: inset)
    return Raster { context in
        for element in rig.body {
            let path = element.path.applying(placement)
            context.addPath(path.cgPath)
            context.fillPath()
            if let stroke = element.stroke {
                let outline = path.strokedPath(StrokeStyle(
                    lineWidth: stroke.width * size / max(rig.viewBox.width, rig.viewBox.height),
                    lineCap: stroke.round ? .round : .butt,
                    lineJoin: stroke.round ? .round : .miter
                ))
                context.addPath(outline.cgPath)
                context.fillPath()
            }
        }
    }
}

func vertices(of path: Path) -> [CGPoint] {
    var points: [CGPoint] = []
    path.forEach { element in
        switch element {
        case .move(let to), .line(let to): points.append(to)
        case .quadCurve(let to, _): points.append(to)
        case .curve(let to, _, _): points.append(to)
        case .closeSubpath: break
        }
    }
    return points
}

func centroid(of path: Path) -> CGPoint {
    let points = vertices(of: path)
    let count = Double(points.count)
    return CGPoint(x: points.map(\.x).reduce(0, +) / count, y: points.map(\.y).reduce(0, +) / count)
}

func verticalTilt(of path: Path) -> Double {
    let points = vertices(of: path)
    let middle = centroid(of: path)
    var xx = 0.0
    var yy = 0.0
    var xy = 0.0
    for point in points {
        let dx = point.x - middle.x
        let dy = point.y - middle.y
        xx += dx * dx
        yy += dy * dy
        xy += dx * dy
    }
    let axis = 0.5 * atan2(2 * xy, xx - yy)
    let fromVertical = axis - Double.pi / 2
    let wrapped = atan2(sin(fromVertical), cos(fromVertical))
    let folded = abs(wrapped) > Double.pi / 2 ? Double.pi - abs(wrapped) : abs(wrapped)
    return folded * 180 / Double.pi
}
