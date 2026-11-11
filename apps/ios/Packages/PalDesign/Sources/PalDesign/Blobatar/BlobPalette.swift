import Foundation

struct Oklch {
    var l: Double
    var c: Double
    var h: Double
}

enum BlobPalette {
    struct Colors: Equatable {
        var bg: String
        var head: String
        var eye: String
    }

    private static let darkSurface = Oklch(l: 0.145, c: 0, h: 0)
    private static let surfaceFloor = 1.5

    private static let tones: [(Double, l: Double, c: Double)] = [
        (0.2, 0.86, 0.085),
        (0.36, 0.9, 0.028),
        (0.62, 0.73, 0.135),
        (0.8, 0.62, 0.165),
        (0.93, 0.87, 0.16),
        (1.0, 0.34, 0.035),
    ]

    static func colors(hue: Double, tone: Double) -> Colors {
        let bg = Oklch(l: 0.965, c: 0.01, h: hue)
        let base = ramp(hue: hue, tone: tone)
        let head = ensureContrast(base.head, against: bg, minimum: 1.25)
        let eye = ensureContrast(base.eye, against: head, minimum: 4.5)
        return Colors(bg: toHex(bg), head: toHex(head), eye: toHex(eye))
    }

    private static func ramp(hue: Double, tone: Double) -> (head: Oklch, eye: Oklch) {
        let swatch = tones.first { tone < $0.0 } ?? tones[0]
        let head = ensureContrast(Oklch(l: swatch.l, c: swatch.c, h: hue), against: darkSurface, minimum: surfaceFloor)
        let eye = head.l >= 0.5 ? Oklch(l: 0.17, c: 0.02, h: hue) : Oklch(l: 0.97, c: 0.012, h: hue)
        return (head, eye)
    }

    private static func toLinear(_ color: Oklch) -> [Double] {
        let radians = (color.h * Double.pi) / 180
        let a = color.c * cos(radians)
        let b = color.c * sin(radians)
        let l_ = color.l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = color.l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = color.l - 0.0894841775 * a - 1.291485548 * b
        let l = l_ * l_ * l_
        let m = m_ * m_ * m_
        let s = s_ * s_ * s_
        return [
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s,
        ]
    }

    private static func inGamut(_ rgb: [Double]) -> Bool {
        rgb.allSatisfy { $0 >= -1e-4 && $0 <= 1 + 1e-4 }
    }

    private static func resolve(_ color: Oklch) -> [Double] {
        var rgb = toLinear(color)
        if !inGamut(rgb) {
            var lo = 0.0
            var hi = color.c
            for _ in 0..<12 {
                let mid = (lo + hi) / 2
                var probe = color
                probe.c = mid
                if inGamut(toLinear(probe)) { lo = mid } else { hi = mid }
            }
            var final = color
            final.c = lo
            rgb = toLinear(final)
        }
        return rgb.map { min(1, max(0, $0)) }
    }

    private static func luminance(_ color: Oklch) -> Double {
        let rgb = resolve(color)
        return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
    }

    private static func contrast(_ a: Oklch, _ b: Oklch) -> Double {
        let x = luminance(a)
        let y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    private static func ensureContrast(_ foreground: Oklch, against background: Oklch, minimum: Double) -> Oklch {
        if contrast(foreground, background) >= minimum { return foreground }
        let lean: Double = foreground.l >= background.l ? 1 : -1
        for direction in [lean, -lean] {
            var probe = foreground
            for _ in 0..<60 {
                probe.l = min(1, max(0, probe.l + direction * 0.02))
                if contrast(probe, background) >= minimum { return probe }
                if probe.l == 0 || probe.l == 1 { break }
            }
        }
        let black = Oklch(l: 0, c: 0, h: foreground.h)
        let white = Oklch(l: 1, c: 0, h: foreground.h)
        return contrast(black, background) >= contrast(white, background) ? black : white
    }

    private static func toHex(_ color: Oklch) -> String {
        let encoded = resolve(color).map { value -> String in
            let s = value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
            let byte = Int(JSCompat.round(s * 255))
            let hex = String(byte, radix: 16)
            return hex.count < 2 ? "0" + hex : hex
        }
        return "#" + encoded.joined()
    }
}
