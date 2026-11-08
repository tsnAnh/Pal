import SwiftUI
import UIKit

extension Color {
    static let canvas = adaptive(dark: 0x121212, light: 0xF2F2F7)
    static let card = adaptive(dark: 0x242424, light: 0xFFFFFF)
    static let cardOutline = adaptive(dark: 0x3D3D3D, light: 0xE0E0E6)
    static let chip = adaptive(dark: 0x383838, light: 0xEEEEF3)
    static let chipOutline = adaptive(dark: 0x525252, light: 0xD3D3DA)
    static let badgeRing = adaptive(dark: 0x000000, light: 0xF2F2F7)
    static let onCard = adaptive(dark: 0xFFFFFF, light: 0x111114)
    static let action = adaptive(dark: 0xFFFFFF, light: 0x1C1C1E)
    static let onAction = adaptive(dark: 0x000000, light: 0xFFFFFF)

    private static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255,
                alpha: 1
            )
        })
    }
}
