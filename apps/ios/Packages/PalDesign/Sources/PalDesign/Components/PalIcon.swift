import SwiftUI

public enum PalIconInk: Equatable, Sendable {
    case primary
    case secondary
    case tertiary
    case destructive
    case success
    case onFill
    case onInverseFill
    case custom(Color)

    public func resolvedRGB(in palette: PalPalette) -> RGB? {
        switch self {
        case .primary: palette.textPrimary
        case .secondary: palette.textSecondary
        case .tertiary: palette.textTertiary
        case .destructive: palette.destructive
        case .success: palette.workingDot
        case .onFill: palette.primaryBadgeGlyph
        case .onInverseFill: palette.chipSelectedText
        case .custom: nil
        }
    }

    func resolved(in palette: PalPalette) -> Color {
        if case .custom(let color) = self { return color }
        return Color(resolvedRGB(in: palette) ?? palette.textPrimary)
    }
}

public struct PalIcon: View {
    private let systemName: String
    private let ink: PalIconInk

    public init(_ systemName: String, ink: PalIconInk = .primary) {
        self.systemName = systemName
        self.ink = ink
    }

    public var body: some View {
        Image(systemName: systemName).palIcon(ink)
    }
}

private struct PalIconStyle: ViewModifier {
    let ink: PalIconInk

    @Environment(\.hermesTheme) private var theme

    func body(content: Content) -> some View {
        let color = ink.resolved(in: theme.palette)
        content.foregroundStyle(color).tint(color)
    }
}

public extension View {
    func palIcon(_ ink: PalIconInk = .primary) -> some View {
        modifier(PalIconStyle(ink: ink))
    }
}

public extension Label where Title == Text, Icon == PalIcon {
    init(_ title: LocalizedStringKey, palIcon name: String, ink: PalIconInk = .primary) {
        self.init {
            Text(title)
        } icon: {
            PalIcon(name, ink: ink)
        }
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, palIcon name: String, ink: PalIconInk = .primary) {
        self.init {
            Text(title)
        } icon: {
            PalIcon(name, ink: ink)
        }
    }
}
