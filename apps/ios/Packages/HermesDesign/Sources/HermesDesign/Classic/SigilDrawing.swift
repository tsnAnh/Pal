import CoreGraphics
import SwiftUI

enum SigilDrawing {
    static let viewBox = CGSize(width: 40, height: 40)

    private struct Rng {
        private var state: UInt32

        init(text: String) {
            var h: UInt32 = 2_166_136_261
            for scalar in text.unicodeScalars {
                h ^= JSCompat.firstUTF16Unit(of: scalar)
                h = h &* 16_777_619
            }
            state = h == 0 ? 88_675_123 : h
        }

        mutating func next() -> Double {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return Double(state) / 4_294_967_296
        }
    }

    private static let diamond = "M20 4 L36 20 L20 36 L4 20 Z"
    private static let eyeDiameter = 4.8

    static func make(_ sigil: SigilAvatar) -> AvatarRig {
        var rng = Rng(text: "\(sigil.name)::\(sigil.seed)")
        func gx(_ i: Int) -> Int { 6 + i * 7 }
        func gy(_ j: Int) -> Int { 8 + j * 6 }
        var strokes: [String] = []
        let segments = 4 + Int((rng.next() * 3).rounded(.down))

        for _ in 0..<segments {
            let x1 = Int((rng.next() * 3).rounded(.down))
            let y1 = Int((rng.next() * 5).rounded(.down))
            let x2 = min(2, max(0, x1 + (rng.next() > 0.5 ? 1 : -1)))
            let y2 = min(4, max(0, y1 + Int((rng.next() * 3).rounded(.down)) - 1))
            strokes.append("M\(gx(x1)) \(gy(y1)) L\(gx(x2)) \(gy(y2))")
            strokes.append("M\(gx(4 - x1)) \(gy(y1)) L\(gx(4 - x2)) \(gy(y2))")
            if rng.next() > 0.6 {
                strokes.append("M\(gx(x2)) \(gy(y2)) L\(gx(4 - x2)) \(gy(y2))")
            }
        }

        strokes.append("M20 \(gy(0)) L20 \(gy(4))")
        let hasRing = rng.next() > 0.45
        let color = sigil.color
        var elements: [AvatarDrawing.Element] = []

        if hasRing {
            elements.append(.init(
                path: SVGPathData.path(diamond),
                fill: nil,
                stroke: .init(color: color, width: 1.2, round: false),
                opacity: 0.5
            ))
        }
        elements.append(.init(
            path: SVGPathData.path(strokes.joined(separator: " ")),
            fill: nil,
            stroke: .init(color: color, width: 2.2, round: true)
        ))
        let rest = [16.0, 24.0].map { EyePlacement(centre: CGPoint(x: $0, y: 14), angle: 0, scale: 1) }

        return AvatarRig(
            viewBox: viewBox,
            clipsToViewBox: false,
            body: elements,
            eyes: .init(
                size: CGSize(width: eyeDiameter, height: eyeDiameter),
                fill: color,
                rest: rest,
                facing: rest,
                mask: [.init(path: SVGPathData.path(diamond), fill: color, stroke: nil)],
                travel: 20
            ),
            bounds: CGRect(x: 4, y: 4, width: 32, height: 32)
        )
    }
}
