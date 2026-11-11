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
            Button(action: onLeading) {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel(Text(leading.accessibilityLabel))
            .accessibilityIdentifier(leadingAccessibilityIdentifier ?? "\(accessibilityIdentifier)-back")
            .tint(.primary)
        }
    }
    #endif

    private var header: some View {
        ZStack {
            if let title, titleAlignment == .centered {
                titleText(title)
            }
            HStack(spacing: 0) {
                Button(action: onLeading) {
                    Image(systemName: leading.systemName)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(Text(leading.accessibilityLabel))
                .accessibilityIdentifier(leadingAccessibilityIdentifier ?? "\(accessibilityIdentifier)-\(leading.identifierSuffix)")
                if let title, titleAlignment == .afterLeadingButton {
                    titleText(title).padding(.leading, 16)
                }
                Spacer(minLength: 0)
                trailing
            }
        }
        .padding(.horizontal, PalMetrics.sheetHeaderHorizontalPadding)
        .padding(.top, PalMetrics.sheetHeaderTopPadding)
        .padding(.bottom, PalMetrics.sheetHeaderBottomGap)
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
        leadingAccessibilityIdentifier: String? = nil,
        onLeading: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            leading: leading,
            titleAlignment: titleAlignment,
            surface: surface,
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
