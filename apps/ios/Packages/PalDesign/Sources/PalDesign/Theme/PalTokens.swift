import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct PalSwatch: Sendable {
    struct Ink: Sendable {
        let hex: UInt32
        let alpha: Double
    }

    let dark: Ink
    let light: Ink

    init(dark: (UInt32, Double), light: (UInt32, Double)) {
        self.dark = Ink(hex: dark.0, alpha: dark.1)
        self.light = Ink(hex: light.0, alpha: light.1)
    }

    func ink(isDark: Bool) -> Ink { isDark ? dark : light }

    func solid(isDark: Bool, over base: RGB) -> RGB {
        let ink = ink(isDark: isDark)
        return base.mixed(with: RGB(hex: ink.hex), fraction: ink.alpha)
    }

    var color: Color {
        let dark = dark
        let light = light
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            let ink = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((ink.hex >> 16) & 255) / 255,
                green: CGFloat((ink.hex >> 8) & 255) / 255,
                blue: CGFloat(ink.hex & 255) / 255,
                alpha: ink.alpha
            )
        })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            let ink = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((ink.hex >> 16) & 255) / 255,
                green: CGFloat((ink.hex >> 8) & 255) / 255,
                blue: CGFloat(ink.hex & 255) / 255,
                alpha: ink.alpha
            )
        })
        #endif
    }
}

enum PalSwatches {
    static let sidebar = PalSwatch(dark: (0x0E0E0E, 1), light: (0xF5F5F5, 1))
    static let content = PalSwatch(dark: (0x121212, 1), light: (0xFCFCFC, 1))
    static let elevated = PalSwatch(dark: (0x1F1F1F, 1), light: (0xFFFFFF, 1))
    static let control = PalSwatch(dark: (0x272727, 1), light: (0xF0F0F0, 1))

    static let textPrimary = PalSwatch(dark: (0xF5F5F5, 1), light: (0x1C1C1C, 1))
    static let textSecondary = PalSwatch(dark: (0xF5F5F5, 0.66), light: (0x1C1C1C, 0.68))
    static let textTertiary = PalSwatch(dark: (0xF5F5F5, 0.54), light: (0x1C1C1C, 0.56))

    static let hover = PalSwatch(dark: (0xF5F5F5, 0.06), light: (0x1C1C1C, 0.06))
    static let chipFill = PalSwatch(dark: (0xF5F5F5, 0.042), light: (0x1C1C1C, 0.05))
    static let selected = PalSwatch(dark: (0xF5F5F5, 0.08), light: (0x1C1C1C, 0.08))
    static let borderStrong = PalSwatch(dark: (0xF5F5F5, 0.10), light: (0x1C1C1C, 0.12))
    static let divider = PalSwatch(dark: (0xF5F5F5, 0.06), light: (0x1C1C1C, 0.08))
    static let hairline = PalSwatch(dark: (0xF5F5F5, 0.03), light: (0x1C1C1C, 0.05))

    static let panelBorder = PalSwatch(dark: (0x252525, 1), light: (0x1C1C1C, 0.12))
    static let fieldBorder = PalSwatch(dark: (0x292929, 1), light: (0x1C1C1C, 0.14))

    static let agentBubbleTop = PalSwatch(dark: (0x242424, 1), light: (0xFFFFFF, 1))
    static let agentBubbleBottom = PalSwatch(dark: (0x1C1C1C, 1), light: (0xF2F2F2, 1))
    static let userBubble = PalSwatch(dark: (0xF5F5F5, 0.18), light: (0x1C1C1C, 1))

    static let scrim = PalSwatch(dark: (0x000000, 0.70), light: (0x000000, 0.50))

    static let toggleOn = PalSwatch(dark: (0x326CCB, 1), light: (0x326CCB, 1))
    static let toggleOff = PalSwatch(dark: (0xF5F5F5, 0.14), light: (0x1C1C1C, 0.14))
    static let inverseFill = PalSwatch(dark: (0xF5F5F5, 1), light: (0x1C1C1C, 1))
    static let inverseText = PalSwatch(dark: (0x1C1C1C, 1), light: (0xF5F5F5, 1))
}

public enum PalTokens {
    public static let sidebar = PalSwatches.sidebar.color
    public static let content = PalSwatches.content.color
    public static let elevated = PalSwatches.elevated.color
    public static let control = PalSwatches.control.color

    public static let textPrimary = PalSwatches.textPrimary.color
    public static let textSecondary = PalSwatches.textSecondary.color
    public static let textTertiary = PalSwatches.textTertiary.color

    public static let hover = PalSwatches.hover.color
    public static let chipFill = PalSwatches.chipFill.color
    public static let selected = PalSwatches.selected.color
    public static let borderStrong = PalSwatches.borderStrong.color
    public static let divider = PalSwatches.divider.color
    public static let hairline = PalSwatches.hairline.color

    public static let panelBorder = PalSwatches.panelBorder.color
    public static let fieldBorder = PalSwatches.fieldBorder.color

    public static let agentBubbleTop = PalSwatches.agentBubbleTop.color
    public static let agentBubbleBottom = PalSwatches.agentBubbleBottom.color
    public static let userBubble = PalSwatches.userBubble.color

    public static let scrim = PalSwatches.scrim.color

    public static let toggleOn = PalSwatches.toggleOn.color
    public static let toggleOff = PalSwatches.toggleOff.color
    public static let inverseFill = PalSwatches.inverseFill.color
    public static let inverseText = PalSwatches.inverseText.color
}

public struct PalHairline: View {
    public var color: Color
    public var axis: Axis

    public init(color: Color = PalTokens.divider, axis: Axis = .horizontal) {
        self.color = color
        self.axis = axis
    }

    public var body: some View {
        switch axis {
        case .horizontal: Rectangle().fill(color).frame(height: 1)
        case .vertical: Rectangle().fill(color).frame(width: 1)
        }
    }
}

public extension Color {
    init(rgb: UInt32) {
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 255) / 255,
            green: Double((rgb >> 8) & 255) / 255,
            blue: Double(rgb & 255) / 255,
            opacity: 1
        )
    }
}
