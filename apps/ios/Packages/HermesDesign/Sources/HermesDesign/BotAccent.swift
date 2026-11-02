import Foundation
import SwiftUI

public struct BotAccent: Equatable, Sendable {
    public let accentHex: String
    public let foregroundHex: String

    public var accent: Color { Self.color(hex: accentHex) }
    public var foreground: Color { Self.color(hex: foregroundHex) }

    public init?(name: String, meta: BotAvatarMeta?) {
        let resolved = BotAvatarSpec.resolvedColor(name: name, meta: meta ?? BotAvatarMeta())
        guard let accent = BotAccent.normalizeHex(resolved.css) ?? BotAccent.hslToHex(resolved.css) else { return nil }
        self.accentHex = accent
        self.foregroundHex = BotAccent.readableInk(on: accent)
    }

    public init?(name: String, uiMeta: [String: Any]?) {
        self.init(name: name, meta: BotAvatarMeta(uiMeta: uiMeta))
    }

    private static func color(hex: String) -> Color {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return Color(
            .sRGB,
            red: Double((value >> 16) & 255) / 255,
            green: Double((value >> 8) & 255) / 255,
            blue: Double(value & 255) / 255,
            opacity: 1
        )
    }

    private static let hexDigits = try! NSRegularExpression(pattern: "\\A[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?\\z")
    private static let hslPrefix = try! NSRegularExpression(
        pattern: "\\A[hH][sS][lL](?:[aA])?\\([\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]*(-?[0-9.]+)(?:[dD][eE][gG])?[\\s,]+([0-9.]+)%[\\s,]+([0-9.]+)%"
    )

    private static func clampChannel(_ value: Double) -> Int {
        Int(min(255, max(0, JSCompat.round(value))))
    }

    private static func hex(_ rgb: [Double]) -> String {
        "#" + rgb.map { channel in
            let text = String(clampChannel(channel), radix: 16)
            return text.count < 2 ? "0" + text : text
        }.joined()
    }

    static func normalizeHex(_ input: String) -> String? {
        var clean = JSCompat.trim(input)
        if clean.hasPrefix("#") { clean.removeFirst() }
        if clean.count == 3 || clean.count == 4 { clean = clean.flatMap { [$0, $0] }.map(String.init).joined() }
        let range = NSRange(clean.startIndex..., in: clean)
        guard hexDigits.firstMatch(in: clean, range: range) != nil else { return nil }
        let digits = Array(clean)
        func byte(_ offset: Int) -> Double {
            Double(UInt8(String(digits[offset..<offset + 2]), radix: 16) ?? 0)
        }
        let rgb = [byte(0), byte(2), byte(4)]
        if digits.count == 6 { return hex(rgb) }
        let alpha = byte(6) / 255
        return hex(rgb.map { $0 * alpha })
    }

    static func hslToHex(_ color: String) -> String? {
        let trimmed = JSCompat.trim(color)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = hslPrefix.firstMatch(in: trimmed, range: range), match.numberOfRanges == 4 else { return nil }
        func group(_ index: Int) -> Double? {
            Range(match.range(at: index), in: trimmed).flatMap { Double(trimmed[$0]) }
        }
        guard let rawHue = group(1), let rawSaturation = group(2), let rawLightness = group(3) else { return nil }
        let hue = ((rawHue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)) / 30
        let saturation = min(rawSaturation, 100) / 100
        let lightness = min(rawLightness, 100) / 100
        let spread = saturation * min(lightness, 1 - lightness)

        func channel(_ offset: Double) -> String {
            let k = (offset + hue).truncatingRemainder(dividingBy: 12)
            let value = lightness - spread * max(-1, min(k - 3, 9 - k, 1))
            let text = String(Int(JSCompat.round(value * 255)), radix: 16)
            return text.count < 2 ? "0" + text : text
        }

        return "#\(channel(0))\(channel(8))\(channel(4))"
    }

    private static func channelLuminance(_ value: Double) -> Double {
        let normalized = value / 255
        return normalized <= 0.03928 ? normalized / 12.92 : pow((normalized + 0.055) / 1.055, 2.4)
    }

    private static func luminance(hex: String) -> Double? {
        guard hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        let r = Double((value >> 16) & 255)
        let g = Double((value >> 8) & 255)
        let b = Double(value & 255)
        return 0.2126 * channelLuminance(r) + 0.7152 * channelLuminance(g) + 0.0722 * channelLuminance(b)
    }

    private static func contrastRatio(_ a: String, _ b: String) -> Double? {
        guard let la = luminance(hex: a), let lb = luminance(hex: b) else { return nil }
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static let inks = ["#161616", "#ffffff"]

    static func readableInk(on background: String) -> String {
        var best = inks[inks.count - 1]
        var bestRatio = -1.0
        for ink in inks {
            if let ratio = contrastRatio(background, ink), ratio >= bestRatio {
                best = ink
                bestRatio = ratio
            }
        }
        return best
    }
}
