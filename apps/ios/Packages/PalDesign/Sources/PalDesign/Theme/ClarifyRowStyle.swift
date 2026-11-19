import Foundation

public enum ClarifyRowStyle: Sendable {
    case choice
    case chosen

    public func text(in palette: PalPalette) -> RGB {
        self == .chosen ? palette.textPrimary : palette.textSecondary
    }

    public func badgeFill(in palette: PalPalette) -> RGB? {
        self == .chosen ? palette.chipSelectedFill : nil
    }

    public func badgeText(in palette: PalPalette) -> RGB {
        self == .chosen ? palette.chipSelectedText : palette.textSecondary
    }

    public func placeholder(in palette: PalPalette) -> RGB { ClarifyRowStyle.choice.text(in: palette) }

    public func typedText(in palette: PalPalette) -> RGB { ClarifyRowStyle.chosen.text(in: palette) }
}

public enum ClarifyBadgeColor: Equatable, Sendable {
    case palette(RGB)
    case botAccent(BotAccent)
}

extension ClarifyRowStyle {
    public func badgeFill(in palette: PalPalette, accent: BotAccent?) -> ClarifyBadgeColor? {
        guard self == .chosen else { return nil }
        return accent.map(ClarifyBadgeColor.botAccent) ?? .palette(palette.chipSelectedFill)
    }

    public func badgeText(in palette: PalPalette, accent: BotAccent?) -> ClarifyBadgeColor {
        guard self == .chosen else { return .palette(palette.textSecondary) }
        return accent.map(ClarifyBadgeColor.botAccent) ?? .palette(palette.chipSelectedText)
    }
}
