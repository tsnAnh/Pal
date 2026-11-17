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

public enum SheetHeaderStyle: Sendable {
    case standard
    case toolbarRow

    public var topPadding: CGFloat { self == .standard ? PalMetrics.sheetHeaderTopPadding : 0 }
    public var bottomGap: CGFloat { self == .standard ? PalMetrics.sheetHeaderBottomGap : 0 }
    public var rowHeight: CGFloat? { self == .toolbarRow ? PalMetrics.sheetCloseControlSize : nil }
    public var titleFollowsLeadingButton: Bool { self == .toolbarRow }
    public var trailingFollowsTitle: Bool { self == .toolbarRow }
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
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(background.ignoresSafeArea())
        .presentationBackground(background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
        #endif
    }

    #if os(iOS)
    private var usesSystemBack: Bool { hostedInNavigation && leading == .back }

    private var navigationContent: some View {
        content
            .environment(\.sheetChromeHostedInNavigation, false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(background.ignoresSafeArea())
            .navigationTitle(title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(!usesSystemBack)
            .toolbar {
                if !usesSystemBack {
                    ToolbarItem(placement: .topBarLeading) { leadingButton }
                }
                if Trailing.self != EmptyView.self {
                    ToolbarItem(placement: .topBarTrailing) { trailing }
                }
            }
            .presentationBackground(background)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(accessibilityIdentifier)
    }

    @ViewBuilder
    private var leadingButton: some View {
        switch leading {
        case .close:
            Button(role: .close, action: onLeading)
                .accessibilityIdentifier(leadingAccessibilityIdentifier ?? "\(accessibilityIdentifier)-close")
                .tint(.primary)
        case .back:
            Button(action: onLeading) { // nav-chrome: ok
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel(Text(leading.accessibilityLabel))
            .accessibilityIdentifier(leadingAccessibilityIdentifier ?? "\(accessibilityIdentifier)-back")
            .tint(.primary)
        }
    }
    #endif

    private var inlineTitle: Bool { titleAlignment == .afterLeadingButton || headerStyle.titleFollowsLeadingButton }

    private var header: some View {
        ZStack {
            if let title, !inlineTitle {
                titleText(title)
            }
            HStack(spacing: 0) {
                Button(action: onLeading) {
                    Image(systemName: leading.systemName)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(PalTokens.textSecondary)
                        .frame(width: 33, height: 33)
                        .palGlass(Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(Text(leading.accessibilityLabel))
                .accessibilityIdentifier(leadingAccessibilityIdentifier ?? "\(accessibilityIdentifier)-\(leading.identifierSuffix)")
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
