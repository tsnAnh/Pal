import CoreGraphics
import SwiftUI

enum SVGPathData {
    static func path(_ data: String) -> Path {
        var parser = Parser(Array(data.utf8))
        return parser.parse()
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var path = Path()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func parse() -> Path {
            var command: UInt8 = 0
            while true {
                skipSeparators()
                guard index < bytes.count else { break }
                if isCommand(bytes[index]) {
                    command = bytes[index]
                    index += 1
                    if command == UInt8(ascii: "Z") || command == UInt8(ascii: "z") {
                        path.closeSubpath()
                        current = subpathStart
                        continue
                    }
                } else if command == 0 {
                    break
                }
                guard apply(command) else { break }
                if command == UInt8(ascii: "M") { command = UInt8(ascii: "L") }
                if command == UInt8(ascii: "m") { command = UInt8(ascii: "l") }
            }
            return path
        }

        private func isCommand(_ byte: UInt8) -> Bool {
            switch byte {
            case UInt8(ascii: "M"), UInt8(ascii: "m"), UInt8(ascii: "L"), UInt8(ascii: "l"), UInt8(ascii: "H"),
                 UInt8(ascii: "h"), UInt8(ascii: "V"), UInt8(ascii: "v"), UInt8(ascii: "C"), UInt8(ascii: "c"),
                 UInt8(ascii: "Q"), UInt8(ascii: "q"), UInt8(ascii: "A"), UInt8(ascii: "a"), UInt8(ascii: "Z"),
                 UInt8(ascii: "z"):
                true
            default:
                false
            }
        }

        private mutating func skipSeparators() {
            while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x2C || bytes[index] == 0x0A || bytes[index] == 0x09 {
                index += 1
            }
        }

        private mutating func number() -> Double? {
            skipSeparators()
            let start = index
            if index < bytes.count, bytes[index] == 0x2D || bytes[index] == 0x2B { index += 1 }
            var digits = 0
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1; digits += 1 }
            if index < bytes.count, bytes[index] == 0x2E {
                index += 1
                while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1; digits += 1 }
            }
            guard digits > 0 else {
                index = start
                return nil
            }
            if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
                var probe = index + 1
                if probe < bytes.count, bytes[probe] == 0x2D || bytes[probe] == 0x2B { probe += 1 }
                if probe < bytes.count, bytes[probe] >= 0x30, bytes[probe] <= 0x39 {
                    while probe < bytes.count, bytes[probe] >= 0x30, bytes[probe] <= 0x39 { probe += 1 }
                    index = probe
                }
            }
            return Double(String(decoding: bytes[start..<index], as: UTF8.self))
        }

        private mutating func numbers(_ count: Int) -> [Double]? {
            var values: [Double] = []
            for _ in 0..<count {
                guard let value = number() else { return nil }
                values.append(value)
            }
            return values
        }

        private mutating func apply(_ command: UInt8) -> Bool {
            let relative = command >= UInt8(ascii: "a")
            let origin = relative ? current : .zero
            func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: origin.x + x, y: origin.y + y) }

            switch command & 0xDF {
            case UInt8(ascii: "M"):
                guard let v = numbers(2) else { return false }
                current = point(v[0], v[1])
                subpathStart = current
                path.move(to: current)
            case UInt8(ascii: "L"):
                guard let v = numbers(2) else { return false }
                current = point(v[0], v[1])
                path.addLine(to: current)
            case UInt8(ascii: "H"):
                guard let v = numbers(1) else { return false }
                current = CGPoint(x: origin.x + v[0], y: current.y)
                path.addLine(to: current)
            case UInt8(ascii: "V"):
                guard let v = numbers(1) else { return false }
                current = CGPoint(x: current.x, y: origin.y + v[0])
                path.addLine(to: current)
            case UInt8(ascii: "C"):
                guard let v = numbers(6) else { return false }
                let end = point(v[4], v[5])
                path.addCurve(to: end, control1: point(v[0], v[1]), control2: point(v[2], v[3]))
                current = end
            case UInt8(ascii: "Q"):
                guard let v = numbers(4) else { return false }
                let end = point(v[2], v[3])
                path.addQuadCurve(to: end, control: point(v[0], v[1]))
                current = end
            case UInt8(ascii: "A"):
                guard let v = numbers(7) else { return false }
                let end = point(v[5], v[6])
                addArc(rx: v[0], ry: v[1], rotation: v[2], largeArc: v[3] != 0, sweep: v[4] != 0, to: end)
                current = end
            default:
                return false
            }
            return true
        }

        private mutating func addArc(rx rxIn: Double, ry ryIn: Double, rotation: Double, largeArc: Bool, sweep: Bool, to end: CGPoint) {
            let start = current
            var rx = abs(rxIn)
            var ry = abs(ryIn)
            guard start != end else { return }
            guard rx > 0, ry > 0 else {
                path.addLine(to: end)
                return
            }
            let phi = rotation * Double.pi / 180
            let cosPhi = cos(phi)
            let sinPhi = sin(phi)
            let dx = (start.x - end.x) / 2
            let dy = (start.y - end.y) / 2
            let x1 = cosPhi * dx + sinPhi * dy
            let y1 = -sinPhi * dx + cosPhi * dy
            let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
            if lambda > 1 {
                let scale = lambda.squareRoot()
                rx *= scale
                ry *= scale
            }
            let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
            let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
            var factor = (max(0, numerator / denominator)).squareRoot()
            if largeArc == sweep { factor = -factor }
            let cxp = factor * rx * y1 / ry
            let cyp = -factor * ry * x1 / rx
            let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
            let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

            func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
                let length = hypot(ux, uy) * hypot(vx, vy)
                var value = acos(max(-1, min(1, (ux * vx + uy * vy) / (length == 0 ? 1 : length))))
                if ux * vy - uy * vx < 0 { value = -value }
                return value
            }

            let theta1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
            var delta = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
            if !sweep, delta > 0 { delta -= 2 * Double.pi }
            if sweep, delta < 0 { delta += 2 * Double.pi }

            let segments = max(1, Int((abs(delta) / (Double.pi / 2)).rounded(.up)))
            let step = delta / Double(segments)
            let alpha = 4.0 / 3.0 * tan(step / 4)
            var theta = theta1
            for _ in 0..<segments {
                let cos1 = cos(theta)
                let sin1 = sin(theta)
                let cos2 = cos(theta + step)
                let sin2 = sin(theta + step)
                func map(_ x: Double, _ y: Double) -> CGPoint {
                    CGPoint(x: cosPhi * rx * x - sinPhi * ry * y + cx, y: sinPhi * rx * x + cosPhi * ry * y + cy)
                }
                path.addCurve(
                    to: map(cos2, sin2),
                    control1: map(cos1 - alpha * sin1, sin1 + alpha * cos1),
                    control2: map(cos2 + alpha * sin2, sin2 - alpha * cos2)
                )
                theta += step
            }
        }
    }
}
