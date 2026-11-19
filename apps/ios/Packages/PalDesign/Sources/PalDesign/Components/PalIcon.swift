import SwiftUI

public enum PalIconInk: Equatable, Sendable {
    case primary
    case secondary
    case tertiary
    case destructive
    case success
    case onFill
    case custom(Color)

    public func resolved(in palette: PalPalette) -> Color {
        switch self {
        case .primary: Color(palette.textPrimary)
        case .secondary: Color(palette.textSecondary)
        case .tertiary: Color(palette.textTertiary)
        case .destructive: Color(palette.destructive)
        case .success: Color(palette.workingDot)
        case .onFill: Color(palette.primaryBadgeGlyph)
        case .custom(let color): color
        }
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
