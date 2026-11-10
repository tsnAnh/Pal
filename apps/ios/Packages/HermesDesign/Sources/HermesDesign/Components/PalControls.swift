import SwiftUI

public extension View {
    func palGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = true) -> some View {
        glassEffect(PalGlass.style(tint: tint, interactive: interactive), in: shape)
    }

    func palElevatedGlass<S: Shape>(_ shape: S) -> some View {
        background(PalTokens.elevated, in: shape).palGlass(shape)
    }
}

enum PalGlass {
    static func style(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        return interactive ? glass.interactive() : glass
    }
}

public struct PalGlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5))
            .foregroundStyle(PalTokens.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .palGlass(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

public extension ButtonStyle where Self == PalGlassButtonStyle {
    static var palGlass: PalGlassButtonStyle { PalGlassButtonStyle() }
}

public struct PalPillButtonStyle: ButtonStyle {
    public var height: CGFloat
    public var fontSize: CGFloat
    public var horizontalPadding: CGFloat
    public var fill: Color?
    public var textColor: Color
    public var disabledOpacity: CGFloat

    @Environment(\.isEnabled) private var isEnabled

    public init(
        height: CGFloat = 30,
        fontSize: CGFloat = 12,
        horizontalPadding: CGFloat = 12,
        fill: Color? = nil,
        textColor: Color = PalTokens.textPrimary,
        disabledOpacity: CGFloat = 0.5
    ) {
        self.height = height
        self.fontSize = fontSize
        self.horizontalPadding = horizontalPadding
        self.fill = fill
        self.textColor = textColor
        self.disabledOpacity = disabledOpacity
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize))
            .foregroundStyle(textColor)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(fill ?? PalTokens.control, in: Capsule())
            .palGlass(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : disabledOpacity)
            .contentShape(Capsule())
    }
}

public extension ButtonStyle where Self == PalPillButtonStyle {
    static var palPill: PalPillButtonStyle { PalPillButtonStyle() }

    static func palPill(
        height: CGFloat = 30,
        fontSize: CGFloat = 12,
        horizontalPadding: CGFloat = 12,
        fill: Color? = nil,
        textColor: Color = PalTokens.textPrimary,
        disabledOpacity: CGFloat = 0.5
    ) -> PalPillButtonStyle {
        PalPillButtonStyle(height: height, fontSize: fontSize, horizontalPadding: horizontalPadding, fill: fill, textColor: textColor, disabledOpacity: disabledOpacity)
    }
}
