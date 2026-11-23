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

public struct SheetGlassButton: View {
    public let leading: SheetLeadingButton
    public let clear: Bool
    public let escapes: Bool
    public let accessibilityIdentifier: String
    public let action: () -> Void

    public init(
        leading: SheetLeadingButton = .close, clear: Bool = false, escapes: Bool = true,
        accessibilityIdentifier: String, action: @escaping () -> Void
    ) {
        self.leading = leading
        self.clear = clear
        self.escapes = escapes
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            PalIcon(leading.systemName, ink: .secondary)
                .font(.system(size: 14, weight: .regular))
                .frame(width: PalMetrics.sheetGlassButtonSize, height: PalMetrics.sheetGlassButtonSize)
                .modifier(SheetGlassSurface(clear: clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(EscapeShortcut(enabled: escapes, leading: leading, action: action))
        .accessibilityLabel(Text(leading.accessibilityLabel))
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct EscapeShortcut: ViewModifier {
    let enabled: Bool
    let leading: SheetLeadingButton
    let action: () -> Void

    @Environment(\.escapeHostLayer) private var hostLayer

    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if let hostLayer {
            if leading == .back {
                content.palEscape(hostLayer, nested: true, dismiss: action)
            } else {
                content
            }
        } else {
            content.keyboardShortcut(.cancelAction)
        }
    }
}

private struct SheetGlassSurface: ViewModifier {
    let clear: Bool

    func body(content: Content) -> some View {
        if clear {
            content.palClearGlass(Circle())
        } else {
            content.palGlass(Circle())
        }
    }
}

#if os(iOS)
public struct SheetCloseButton: View {
    public let accessibilityIdentifier: String
    public let action: () -> Void

    public init(accessibilityIdentifier: String, action: @escaping () -> Void) {
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    public var body: some View {
        Button(role: .close, action: action)
            .accessibilityIdentifier(accessibilityIdentifier)
            .tint(.primary)
    }
}
#endif

public enum SheetTitleAlignment: Sendable {
    case centered
    case afterLeadingButton
}

public enum SheetHeaderStyle: Sendable {
    case standard
    case toolbarRow
    case stepper

    public var topPadding: CGFloat {
        switch self {
        case .standard: PalMetrics.sheetHeaderTopPadding
        case .toolbarRow: 0
        case .stepper: PalMetrics.stepperHeaderTopPadding
        }
    }

    public var bottomGap: CGFloat {
        switch self {
        case .standard: PalMetrics.sheetHeaderBottomGap
        case .toolbarRow: 0
        case .stepper: PalMetrics.stepperHeaderBottomGap
        }
    }

    public var rowHeight: CGFloat? { self == .toolbarRow ? PalMetrics.sheetCloseControlSize : nil }
    public var titleFollowsLeadingButton: Bool { self != .standard }
    public var trailingFollowsTitle: Bool { self != .standard }
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
    public let headerStyle: SheetHeaderStyle
    public let escapes: Bool
    public let accessibilityIdentifier: String
    public let leadingAccessibilityIdentifier: String?
    public let onLeading: () -> Void
    private let trailing: Trailing
    private let content: Content

    @Environment(\.hermesTheme) private var theme

    public init(
        title: String? = nil,
        leading: SheetLeadingButton = .close,
        titleAlignment: SheetTitleAlignment = .centered,
        surface: SheetSurface = .grouped,
        headerStyle: SheetHeaderStyle = .standard,
        escapes: Bool = true,
        accessibilityIdentifier: String,
        leadingAccessibilityIdentifier: String? = nil,
        onLeading: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.leading = leading
        self.titleAlignment = titleAlignment
        self.surface = surface
        self.headerStyle = headerStyle
        self.escapes = escapes
        self.accessibilityIdentifier = accessibilityIdentifier
        self.leadingAccessibilityIdentifier = leadingAccessibilityIdentifier
        self.onLeading = onLeading
        self.trailing = trailing()
        self.content = content()
    }

    private var background: Color {
        Color(surface == .grouped ? theme.palette.sheetBackground : theme.palette.canvas)
    }

    @Environment(\.sheetChromeHostedInNavigation) private var hostedInNavigation

    public var body: some View {
        #if os(iOS)
        if hostedInNavigation {
            navigationContent
        } else {
            NavigationStack { navigationContent }
        }
        #else
        VStack(spacing: 0) {
            header
            content.safeAreaPadding(.bottom, PalMetrics.sheetBottomInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(background.ignoresSafeArea())
        .presentationBackground(background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
        #endif
    }

    #if os(iOS)
    private var navigationContent: some View {
        AnyView(content)
            .environment(\.sheetChromeHostedInNavigation, false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(background.ignoresSafeArea())
            .navigationTitle(title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(leading == .close)
            .toolbar {
                if leading == .close {
                    ToolbarItem(placement: .topBarLeading) {
                        SheetCloseButton(
                            accessibilityIdentifier: leadingAccessibilityIdentifier ?? "\(accessibilityIdentifier)-close", action: onLeading
                        )
                    }
                }
                if Trailing.self != EmptyView.self {
                    ToolbarItem(placement: .topBarTrailing) { trailing }
                }
            }
            .presentationBackground(background)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(accessibilityIdentifier)
    }
    #endif

    private var inlineTitle: Bool { titleAlignment == .afterLeadingButton || headerStyle.titleFollowsLeadingButton }

    private var header: some View {
        ZStack {
            if let title, !inlineTitle {
                titleText(title)
            }
            HStack(spacing: 0) {
                SheetGlassButton(
                    leading: leading,
                    escapes: escapes,
                    accessibilityIdentifier: leadingAccessibilityIdentifier ?? "\(accessibilityIdentifier)-\(leading.identifierSuffix)",
                    action: onLeading
                )
                if let title, inlineTitle {
                    titleText(title).padding(.leading, 16)
                }
                if headerStyle.trailingFollowsTitle {
                    trailing.padding(.leading, 12)
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    trailing
                }
            }
        }
        .frame(height: headerStyle.rowHeight)
        .padding(.horizontal, PalMetrics.sheetHeaderHorizontalPadding)
        .padding(.top, headerStyle.topPadding)
        .padding(.bottom, headerStyle.bottomGap)
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
        headerStyle: SheetHeaderStyle = .standard,
        escapes: Bool = true,
        accessibilityIdentifier: String,
        leadingAccessibilityIdentifier: String? = nil,
        onLeading: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            leading: leading,
            titleAlignment: titleAlignment,
            surface: surface,
            headerStyle: headerStyle,
            escapes: escapes,
            accessibilityIdentifier: accessibilityIdentifier,
            leadingAccessibilityIdentifier: leadingAccessibilityIdentifier,
            onLeading: onLeading,
            trailing: { EmptyView() },
            content: content
        )
    }
}

extension EnvironmentValues {
    @Entry public var sheetChromeHostedInNavigation = false
}
