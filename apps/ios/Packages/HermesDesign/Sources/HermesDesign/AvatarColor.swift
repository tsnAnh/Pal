import Foundation
import SwiftUI

public struct AvatarColor: Equatable, Hashable, Sendable {
    public let css: String
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public static let darkLuminance = 110.0
    public static let lightEyeFillCSS = "#f3f4fd"
    public static let darkEyeFillCSS = "#1b1b1b"
    public static let primary = AvatarColor(unchecked: "#8b5cf6", red: 139, green: 92, blue: 246, alpha: 1)

    private init(unchecked css: String, red: Double, green: Double, blue: Double, alpha: Double) {
        self.css = css
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init?(css value: String?) {
        guard let value, let parsed = Self.parse(value) else { return nil }
        self = parsed
    }

    public var isDark: Bool {
        0.2126 * red + 0.7152 * green + 0.0722 * blue < Self.darkLuminance
    }

    public var eyeFillCSS: String {
        isDark ? Self.lightEyeFillCSS : Self.darkEyeFillCSS
    }

    public var eyeFill: AvatarColor {
        AvatarColor(css: eyeFillCSS) ?? .primary
    }

    public var swiftUIColor: Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255, opacity: alpha)
    }
}

private enum ColorSyntax {
    static let whitespace = "[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]"
    static let number = "[+-]?(?:[0-9]+\\.?[0-9]*|\\.[0-9]+)"
    static let component = "\(number)%?"
    static let hue = "\(number)(?:[dD][eE][gG])?"
    static let separator = "(?:\(whitespace)*,\(whitespace)*|\(whitespace)+)"
    static let alphaSeparator = "(?:\(whitespace)*,\(whitespace)*|\(whitespace)*/\(whitespace)*)"
    static let alpha = "(?:\(alphaSeparator)(\(component)))?"

    static let hex = regex("\\A#(?:[0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})\\z")

    static let rgb = regex(
        "\\A[rR][gG][bB](?:[aA])?\\(\(whitespace)*(\(component))\(separator)(\(component))\(separator)(\(component))\(alpha)\(whitespace)*\\)\\z"
    )

    static let hsl = regex(
        "\\A[hH][sS][lL](?:[aA])?\\(\(whitespace)*(\(hue))\(separator)(\(component))\(separator)(\(component))\(alpha)\(whitespace)*\\)\\z"
    )

    static func regex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            fatalError("invalid color pattern: \(error)")
        }
    }

    static func groups(_ expression: NSRegularExpression, in text: String) -> [String?]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            let groupRange = match.range(at: index)
            return groupRange.location == NSNotFound ? nil : Range(groupRange, in: text).map { String(text[$0]) }
        }
    }
}

extension AvatarColor {
    fileprivate static func parse(_ value: String) -> AvatarColor? {
        if ColorSyntax.groups(ColorSyntax.hex, in: value) != nil {
            return hex(value)
        }
        if let groups = ColorSyntax.groups(ColorSyntax.rgb, in: value), groups.count == 4 {
            guard let r = groups[0], let g = groups[1], let b = groups[2] else { return nil }
            return AvatarColor(
                unchecked: value, red: channel(r), green: channel(g), blue: channel(b), alpha: alpha(groups[3])
            )
        }
        if let groups = ColorSyntax.groups(ColorSyntax.hsl, in: value), groups.count == 4 {
            guard let h = groups[0], let s = groups[1], let l = groups[2] else { return nil }
            let (red, green, blue) = hslChannels(hue: h, saturation: s, lightness: l)
            return AvatarColor(unchecked: value, red: red, green: green, blue: blue, alpha: alpha(groups[3]))
        }
        return nil
    }

    private static func channel(_ text: String) -> Double {
        let value = JSCompat.parseFloatPrefix(text)
        return min(255, max(0, text.hasSuffix("%") ? value / 100 * 255 : value))
    }

    private static func alpha(_ text: String?) -> Double {
        guard let text else { return 1 }
        let value = JSCompat.parseFloatPrefix(text)
        let resolved = text.hasSuffix("%") ? value / 100 : value
        return min(1, max(0, resolved))
    }

    private static func hex(_ value: String) -> AvatarColor? {
        var digits = Array(value.dropFirst())
        if digits.count <= 4 { digits = digits.flatMap { [$0, $0] } }
        func byte(_ offset: Int) -> Double? {
            UInt8(String(digits[offset..<offset + 2]), radix: 16).map(Double.init)
        }
        guard let r = byte(0), let g = byte(2), let b = byte(4) else { return nil }
        let a = digits.count == 8 ? (byte(6) ?? 255) / 255 : 1
        return AvatarColor(unchecked: value, red: r, green: g, blue: b, alpha: a)
    }

    private static func hslChannels(hue: String, saturation: String, lightness: String) -> (Double, Double, Double) {
        let degrees = JSCompat.parseFloatPrefix(hue)
        let h = ((degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)) / 360
        let s = min(1, max(0, JSCompat.parseFloatPrefix(saturation) / 100))
        let l = min(1, max(0, JSCompat.parseFloatPrefix(lightness) / 100))
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q

        func at(_ offset: Double) -> Double {
            let t = (h + offset + 1).truncatingRemainder(dividingBy: 1)
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }

        return (at(1.0 / 3) * 255, at(0) * 255, at(-1.0 / 3) * 255)
    }
}
