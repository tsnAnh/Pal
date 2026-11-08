import SwiftUI

public struct FloatingSearchBarLeadingButton {
    public let systemName: String
    public let accessibilityLabel: String
    public let accessibilityIdentifier: String
    public let action: () -> Void

    public init(systemName: String, accessibilityLabel: String, accessibilityIdentifier: String, action: @escaping () -> Void) {
        self.systemName = systemName
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }
}

public struct FloatingSearchBar: View {
    @Binding public var text: String
    public let prompt: String
    public let accessibilityLabel: String
    public let accessibilityIdentifier: String
    public let leadingButton: FloatingSearchBarLeadingButton?
    public let trailingButton: FloatingSearchBarLeadingButton?
    public let autoFocus: Bool

    @Environment(\.hermesTheme) private var theme
    @FocusState private var isFocused: Bool

    public init(
        text: Binding<String>,
        prompt: String = "Search",
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        leadingButton: FloatingSearchBarLeadingButton? = nil,
        trailingButton: FloatingSearchBarLeadingButton? = nil,
        autoFocus: Bool = false
    ) {
        _text = text
        self.prompt = prompt
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier
        self.leadingButton = leadingButton
        self.trailingButton = trailingButton
        self.autoFocus = autoFocus
    }

    private var isSearching: Bool { isFocused || !text.isEmpty }

    private var glass: Glass {
        .regular.tint(Color(theme.palette.glassCapsuleFill).opacity(0.9))
    }

    public var body: some View {
        GlassEffectContainer(spacing: HermesMetrics.searchBarLeadingButtonGap) {
            HStack(spacing: HermesMetrics.searchBarLeadingButtonGap) {
                if let leadingButton {
                    glassCircle(
                        systemName: leadingButton.systemName,
                        label: leadingButton.accessibilityLabel,
                        identifier: leadingButton.accessibilityIdentifier,
                        action: leadingButton.action
                    )
                }
                field
                if let trailingButton {
                    glassCircle(
                        systemName: trailingButton.systemName,
                        label: trailingButton.accessibilityLabel,
                        identifier: trailingButton.accessibilityIdentifier,
                        action: trailingButton.action
                    )
                } else if isSearching {
                    glassCircle(
                        systemName: "xmark",
                        label: "Clear search",
                        identifier: "\(accessibilityIdentifier)-clear"
                    ) {
                        text = ""
                        isFocused = false
                    }
                }
            }
        }
        .padding(.horizontal, HermesMetrics.searchBarHorizontalMargin)
        .padding(.top, 8)
        .padding(.bottom, HermesMetrics.searchBarBottomPadding)
        .animation(.snappy(duration: 0.2), value: isSearching)
        .task {
            guard autoFocus else { return }
            try? await Task.sleep(for: .milliseconds(150))
            isFocused = true
        }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(Color(theme.palette.textPrimary))
                .accessibilityHidden(true)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Color(theme.palette.textSecondary)))
                .hermesText(.searchPrompt)
                .foregroundStyle(Color(theme.palette.textPrimary))
                .searchFieldTraits()
                .focused($isFocused)
                .accessibilityLabel(Text(accessibilityLabel))
                .accessibilityIdentifier(accessibilityIdentifier)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, minHeight: HermesMetrics.searchBarHeight, maxHeight: HermesMetrics.searchBarHeight)
        .background(Color(theme.palette.glassCapsuleFill).opacity(0.85), in: Capsule())
        .glassEffect(glass, in: .capsule)
    }

    private func glassCircle(systemName: String, label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(Color(theme.palette.textPrimary))
                .frame(width: HermesMetrics.searchBarHeight, height: HermesMetrics.searchBarHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(Color(theme.palette.glassCapsuleFill).opacity(0.85), in: Circle())
        .glassEffect(glass.interactive(), in: .circle)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(identifier)
    }
}

extension View {
    fileprivate func searchFieldTraits() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
        #else
        autocorrectionDisabled()
        #endif
    }
}

public struct FloatingSearchLauncher: View {
    public let prompt: String
    public let accessibilityLabel: String
    public let accessibilityIdentifier: String
    public let leadingButton: FloatingSearchBarLeadingButton?
    public let action: () -> Void

    @Environment(\.hermesTheme) private var theme

    public init(
        prompt: String = "Search",
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        leadingButton: FloatingSearchBarLeadingButton? = nil,
        action: @escaping () -> Void
    ) {
        self.prompt = prompt
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier
        self.leadingButton = leadingButton
        self.action = action
    }

    private var glass: Glass {
        .regular.tint(Color(theme.palette.glassCapsuleFill).opacity(0.9))
    }

    public var body: some View {
        GlassEffectContainer(spacing: HermesMetrics.searchBarLeadingButtonGap) {
            HStack(spacing: HermesMetrics.searchBarLeadingButtonGap) {
                if let leadingButton {
                    Button(action: leadingButton.action) {
                        Image(systemName: leadingButton.systemName)
                            .font(.system(size: 19, weight: .regular))
                            .foregroundStyle(Color(theme.palette.textPrimary))
                            .frame(width: HermesMetrics.searchBarHeight, height: HermesMetrics.searchBarHeight)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .background(Color(theme.palette.glassCapsuleFill).opacity(0.85), in: Circle())
        .glassEffect(glass.interactive(), in: .circle)
                    .accessibilityLabel(Text(leadingButton.accessibilityLabel))
                    .accessibilityIdentifier(leadingButton.accessibilityIdentifier)
                }
                Button(action: action) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 19, weight: .regular))
                            .foregroundStyle(Color(theme.palette.textPrimary))
                        Text(prompt)
                            .hermesText(.searchPrompt)
                            .foregroundStyle(Color(theme.palette.textSecondary))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, minHeight: HermesMetrics.searchBarHeight, maxHeight: HermesMetrics.searchBarHeight)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .background(Color(theme.palette.glassCapsuleFill).opacity(0.85), in: Capsule())
                .glassEffect(glass.interactive(), in: .capsule)
                .accessibilityLabel(Text(accessibilityLabel))
                .accessibilityIdentifier(accessibilityIdentifier)
            }
        }
        .padding(.horizontal, HermesMetrics.searchBarHorizontalMargin)
        .padding(.top, 8)
        .padding(.bottom, HermesMetrics.searchBarBottomPadding)
    }
}
