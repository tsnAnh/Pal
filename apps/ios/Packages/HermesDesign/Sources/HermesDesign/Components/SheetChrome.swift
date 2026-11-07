import SwiftUI

public enum SheetLeadingButton: Sendable {
    case close
    case back

    var systemName: String {
        switch self {
        case .close: "xmark"
        case .back: "chevron.left"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .close: "Close"
        case .back: "Back"
        }
    }

    var identifierSuffix: String {
        switch self {
        case .close: "close"
        case .back: "back"
        }
    }
}

public enum SheetTitleAlignment: Sendable {
    case centered
    case afterLeadingButton
}

public enum SheetSurface: Sendable {
    case grouped
    case canvas
}

public struct SheetChrome<Trailing: View, Content: View>: View {
    public let title: String?
    public let leading: SheetLeadingButton
    public let titleAlignment: SheetTitleAlignment
    public let surface: SheetSurface
    public let accessibilityIdentifier: String
    public let onLeading: () -> Void
    private let trailing: Trailing
    private let content: Content

    @Environment(\.hermesTheme) private var theme

    public init(
        title: String? = nil,
        leading: SheetLeadingButton = .close,
        titleAlignment: SheetTitleAlignment = .centered,
        surface: SheetSurface = .grouped,
        accessibilityIdentifier: String,
        onLeading: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.leading = leading
        self.titleAlignment = titleAlignment
        self.surface = surface
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onLeading = onLeading
        self.trailing = trailing()
        self.content = content()
    }

    private var background: Color {
        Color(surface == .grouped ? theme.palette.sheetBackground : theme.palette.canvas)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(background.ignoresSafeArea())
        .presentationBackground(background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var header: some View {
        ZStack {
            if let title, titleAlignment == .centered {
                titleText(title)
            }
            HStack(spacing: 0) {
                CircleIconButton(
                    systemName: leading.systemName,
                    accessibilityLabel: leading.accessibilityLabel,
                    accessibilityIdentifier: "\(accessibilityIdentifier)-\(leading.identifierSuffix)",
                    action: onLeading
                )
                if let title, titleAlignment == .afterLeadingButton {
                    titleText(title).padding(.leading, 16)
                }
                Spacer(minLength: 0)
                trailing
            }
        }
        .padding(.horizontal, HermesMetrics.sheetHeaderHorizontalPadding)
        .padding(.top, HermesMetrics.sheetHeaderTopPadding)
        .padding(.bottom, HermesMetrics.sheetHeaderBottomGap)
    }

    private func titleText(_ title: String) -> some View {
        Text(title)
            .hermesText(.sheetTitle)
            .foregroundStyle(Color(theme.palette.textPrimary))
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("\(accessibilityIdentifier)-title")
    }
}

extension SheetChrome where Trailing == EmptyView {
    public init(
        title: String? = nil,
        leading: SheetLeadingButton = .close,
        titleAlignment: SheetTitleAlignment = .centered,
        surface: SheetSurface = .grouped,
        accessibilityIdentifier: String,
        onLeading: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            leading: leading,
            titleAlignment: titleAlignment,
            surface: surface,
            accessibilityIdentifier: accessibilityIdentifier,
            onLeading: onLeading,
            trailing: { EmptyView() },
            content: content
        )
    }
}
