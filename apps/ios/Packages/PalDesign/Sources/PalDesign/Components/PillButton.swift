import SwiftUI

public enum PillKind: Sendable {
    case neutral
    case dimmed
    case accent
}

public enum PillSize: Sendable {
    case regular
    case large
}

public struct PillButtonStyle: ButtonStyle {
    public let kind: PillKind
    public let size: PillSize

    @Environment(\.hermesTheme) private var theme

    public init(kind: PillKind = .neutral, size: PillSize = .regular) {
        self.kind = kind
        self.size = size
    }

    private var fill: RGB {
        switch kind {
        case .neutral, .dimmed: theme.palette.pillFill
        case .accent: theme.palette.accentBlue
        }
    }

    private var text: RGB {
        switch kind {
        case .neutral: theme.palette.pillText
        case .dimmed: theme.palette.pillDimmedText
        case .accent: theme.palette.accentBlueText
        }
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .hermesText(size == .large ? .largePill : .pill)
            .foregroundStyle(Color(text))
            .padding(.horizontal, size == .large ? PalMetrics.largePillHorizontalPadding : PalMetrics.pillHorizontalPadding)
            .frame(height: size == .large ? PalMetrics.largePillHeight : PalMetrics.pillHeight)
            .background(Color(fill), in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    public static func pill(_ kind: PillKind = .neutral, size: PillSize = .regular) -> PillButtonStyle {
        PillButtonStyle(kind: kind, size: size)
    }
}

public struct PillButton: View {
    public let title: String
    public let kind: PillKind
    public let size: PillSize
    public let isBusy: Bool
    public let accessibilityIdentifier: String
    public let action: () -> Void

    public init(
        _ title: String,
        kind: PillKind = .neutral,
        size: PillSize = .regular,
        isBusy: Bool = false,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.kind = kind
        self.size = size
        self.isBusy = isBusy
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isBusy { ProgressView().controlSize(.small).tint(.white) }
                Text(title)
            }
        }
        .buttonStyle(.pill(kind, size: size))
        .disabled(isBusy || kind == .dimmed)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
