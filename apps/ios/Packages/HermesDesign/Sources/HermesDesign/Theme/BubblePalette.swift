import SwiftUI

public enum BubblePalette {
    private struct Anchor {
        let hue: Double
        let light: UInt32
        let dark: UInt32
    }

    private static let anchors: [Anchor] = [
        Anchor(hue: 22.5, light: 0xD2550A, dark: 0xCD5309),
        Anchor(hue: 34.1, light: 0xC2730B, dark: 0xC8770C),
        Anchor(hue: 151.5, light: 0x0D9655, dark: 0x0E9F5A),
        Anchor(hue: 171.9, light: 0x0D9381, dark: 0x0E9886),
        Anchor(hue: 211.2, light: 0x126FD4, dark: 0x116DD2),
        Anchor(hue: 261.0, light: 0x7442D1, dark: 0x7845D7),
        Anchor(hue: 329.4, light: 0xC82779, dark: 0xCF297E),
        Anchor(hue: 355.2, light: 0xC82532, dark: 0xCF2B35),
    ]

    private static let minimumSaturation = 0.14

    public static let agentBubble = AnyShapeStyle(LinearGradient(
        colors: [PalTokens.agentBubbleTop, PalTokens.agentBubbleBottom],
        startPoint: .top,
        endPoint: .bottom
    ))

    public static func userFill(accent: BotAccent?, isDark: Bool) -> Color {
        guard let accent, let hsl = hueAndSaturation(of: accent.accentHex), hsl.saturation >= minimumSaturation else {
            return PalTokens.userBubble
        }
        return Color(rgb: blended(hue: hsl.hue, isDark: isDark))
    }

    public static let userText = Color.white

    private static func blended(hue: Double, isDark: Bool) -> UInt32 {
        let wrapped = anchors + [Anchor(hue: anchors[0].hue + 360, light: anchors[0].light, dark: anchors[0].dark)]
        let lead = Anchor(hue: anchors[anchors.count - 1].hue - 360, light: anchors[anchors.count - 1].light, dark: anchors[anchors.count - 1].dark)
        let ring = [lead] + wrapped
        let target = hue
        var lower = ring[0]
        var upper = ring[1]
        for index in 0..<(ring.count - 1) where target >= ring[index].hue && target <= ring[index + 1].hue {
            lower = ring[index]
            upper = ring[index + 1]
            break
        }
        let span = upper.hue - lower.hue
        let t = span == 0 ? 0 : (target - lower.hue) / span
        let from = hsl(of: isDark ? lower.dark : lower.light)
        let to = hsl(of: isDark ? upper.dark : upper.light)
        var fromHue = from.hue
        var toHue = to.hue
        if toHue - fromHue > 180 { toHue -= 360 }
        if fromHue - toHue > 180 { fromHue -= 360 }
        let mixedHue = fromHue + (toHue - fromHue) * t
        let saturation = from.saturation + (to.saturation - from.saturation) * t
        var lightness = from.lightness + (to.lightness - from.lightness) * t
        var fill = rgb(hue: mixedHue, saturation: saturation, lightness: lightness)
        while contrastWithWhite(fill) < minimumWhiteContrast, lightness > 0.05 {
            lightness -= 0.005
            fill = rgb(hue: mixedHue, saturation: saturation, lightness: lightness)
        }
        return fill
    }

    private static let minimumWhiteContrast = 4.5

    private static func contrastWithWhite(_ hex: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((hex >> shift) & 255) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        return 1.05 / (luminance + 0.05)
    }

    private static func hsl(of hex: UInt32) -> (hue: Double, saturation: Double, lightness: Double) {
        let r = Double((hex >> 16) & 255) / 255
        let g = Double((hex >> 8) & 255) / 255
        let b = Double(hex & 255) / 255
        let high = max(r, g, b)
        let low = min(r, g, b)
        let delta = high - low
        let lightness = (high + low) / 2
        guard delta > 0 else { return (0, 0, lightness) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        switch high {
        case r: hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        case g: hue = (b - r) / delta + 2
        default: hue = (r - g) / delta + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, saturation, lightness)
    }

    private static func rgb(hue: Double, saturation: Double, lightness: Double) -> UInt32 {
        let wrapped = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let x = chroma * (1 - abs((wrapped / 60).truncatingRemainder(dividingBy: 2) - 1))
        let match = lightness - chroma / 2
        let (r, g, b): (Double, Double, Double)
        switch wrapped {
        case ..<60: (r, g, b) = (chroma, x, 0)
        case ..<120: (r, g, b) = (x, chroma, 0)
        case ..<180: (r, g, b) = (0, chroma, x)
        case ..<240: (r, g, b) = (0, x, chroma)
        case ..<300: (r, g, b) = (x, 0, chroma)
        default: (r, g, b) = (chroma, 0, x)
        }
        func byte(_ value: Double) -> UInt32 { UInt32(((value + match) * 255).rounded()) }
        return (byte(r) << 16) | (byte(g) << 8) | byte(b)
    }

    private static func hueAndSaturation(of hex: String) -> (hue: Double, saturation: Double)? {
        guard hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        let r = Double((value >> 16) & 255) / 255
        let g = Double((value >> 8) & 255) / 255
        let b = Double(value & 255) / 255
        let high = max(r, g, b)
        let low = min(r, g, b)
        let delta = high - low
        guard delta > 0 else { return (0, 0) }
        let lightness = (high + low) / 2
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        switch high {
        case r: hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        case g: hue = (b - r) / delta + 2
        default: hue = (r - g) / delta + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, saturation)
    }
}
