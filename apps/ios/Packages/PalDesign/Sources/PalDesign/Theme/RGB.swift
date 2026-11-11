import Foundation
import SwiftUI

public struct RGB: Equatable, Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(1, max(0, red))
        self.green = min(1, max(0, green))
        self.blue = min(1, max(0, blue))
    }

    public init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 255) / 255,
            green: Double((hex >> 8) & 255) / 255,
            blue: Double(hex & 255) / 255
        )
    }

    public init?(hexString: String) {
        var digits = hexString.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(hex: value)
    }

    public var hex: UInt32 {
        func byte(_ channel: Double) -> UInt32 { UInt32((channel * 255).rounded()) }
        return byte(red) << 16 | byte(green) << 8 | byte(blue)
    }

    public var hexString: String {
        String(format: "#%06x", hex)
    }

    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    public func mixed(with other: RGB, fraction: Double) -> RGB {
        let amount = min(1, max(0, fraction))
        return RGB(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount
        )
    }

    public var hueSaturationBrightness: (hue: Double, saturation: Double, brightness: Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        guard delta > 0 else { return (0, 0, maximum) }
        let sector: Double
        switch maximum {
        case red: sector = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        case green: sector = (blue - red) / delta + 2
        default: sector = (red - green) / delta + 4
        }
        let hue = (sector * 60 + 360).truncatingRemainder(dividingBy: 360) / 360
        return (hue, delta / maximum, maximum)
    }

    public init(hue: Double, saturation: Double, brightness: Double) {
        let sector = (hue - hue.rounded(.down)) * 6
        let index = Int(sector)
        let fraction = sector - Double(index)
        let low = brightness * (1 - saturation)
        let falling = brightness * (1 - saturation * fraction)
        let rising = brightness * (1 - saturation * (1 - fraction))
        switch index % 6 {
        case 0: self.init(red: brightness, green: rising, blue: low)
        case 1: self.init(red: falling, green: brightness, blue: low)
        case 2: self.init(red: low, green: brightness, blue: rising)
        case 3: self.init(red: low, green: falling, blue: brightness)
        case 4: self.init(red: rising, green: low, blue: brightness)
        default: self.init(red: brightness, green: low, blue: falling)
        }
    }

    public func tinted(toward accent: RGB, saturationScale: Double, brightnessLift: Double) -> RGB {
        let own = hueSaturationBrightness
        let target = accent.hueSaturationBrightness
        return RGB(
            hue: target.hue,
            saturation: min(1, target.saturation * saturationScale),
            brightness: min(1, own.brightness + brightnessLift)
        )
    }
}
