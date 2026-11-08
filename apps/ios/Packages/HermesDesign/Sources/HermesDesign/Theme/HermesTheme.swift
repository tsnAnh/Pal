import Foundation
import SwiftUI

public struct HermesTheme: Equatable, Sendable {
    public var mode: AppearanceMode
    public var palette: HermesPalette

    public init(mode: AppearanceMode, palette: HermesPalette) {
        self.mode = mode
        self.palette = palette
    }

    public static let `default` = HermesTheme(mode: .dark, palette: .measuredDark)
}

extension EnvironmentValues {
    @Entry public var hermesTheme: HermesTheme = .default
}

public extension Color {
    init(_ color: RGB) {
        self = color.color
    }
}

private struct HermesThemeRoot: ViewModifier {
    let mode: AppearanceMode
    let botAccent: BotAccent?

    @Environment(\.colorScheme) private var systemScheme

    private var theme: HermesTheme {
        let accent = botAccent.flatMap { RGB(hexString: $0.accentHex) }
        return HermesTheme(mode: mode, palette: mode.palette(systemScheme: systemScheme, botAccent: accent))
    }

    func body(content: Content) -> some View {
        content
            .environment(\.hermesTheme, theme)
            .preferredColorScheme(mode.preferredColorScheme)
            .tint(Color(theme.palette.accentBlue))
    }
}

extension View {
    public func hermesTheme(mode: AppearanceMode, botAccent: BotAccent?) -> some View {
        modifier(HermesThemeRoot(mode: mode, botAccent: botAccent))
    }
}
