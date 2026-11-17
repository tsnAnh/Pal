import Foundation
import SwiftUI

public struct PalTheme: Equatable, Sendable {
    public var mode: AppearanceMode
    public var palette: PalPalette

    public init(mode: AppearanceMode, palette: PalPalette) {
        self.mode = mode
        self.palette = palette
    }

    public func withoutBotTint(systemScheme: ColorScheme) -> PalTheme {
        PalTheme(mode: mode, palette: mode.palette(systemScheme: systemScheme, botAccent: nil))
    }

    public static let `default` = PalTheme(mode: .dark, palette: .measuredDark)
}

extension EnvironmentValues {
    @Entry public var hermesTheme: PalTheme = .default
}

public extension Color {
    init(_ color: RGB) {
        self = color.color
    }
}

private struct PalThemeRoot: ViewModifier {
    let mode: AppearanceMode
    let botAccent: BotAccent?

    @Environment(\.colorScheme) private var systemScheme

    private var theme: PalTheme {
        let accent = botAccent.flatMap { RGB(hexString: $0.accentHex) }
        return PalTheme(mode: mode, palette: mode.palette(systemScheme: systemScheme, botAccent: accent))
    }

    func body(content: Content) -> some View {
        content
            .environment(\.hermesTheme, theme)
            .preferredColorScheme(mode.preferredColorScheme)
            .tint(Color(theme.palette.accentBlue))
    }
}

private struct PalThemeWithoutBotTint: ViewModifier {
    @Environment(\.hermesTheme) private var theme
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        content.environment(\.hermesTheme, theme.withoutBotTint(systemScheme: systemScheme))
    }
}

extension View {
    public func hermesThemeWithoutBotTint() -> some View {
        modifier(PalThemeWithoutBotTint())
    }

    public func hermesTheme(mode: AppearanceMode, botAccent: BotAccent?) -> some View {
        modifier(PalThemeRoot(mode: mode, botAccent: botAccent))
    }
}
