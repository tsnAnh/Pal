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
    public let autoFocus: Bool

    @Environment(\.hermesTheme) private var theme
    @FocusState private var isFocused: Bool

    public init(
        text: Binding<String>,
        prompt: String = "Search",
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        leadingButton: FloatingSearchBarLeadingButton? = nil,
        autoFocus: Bool = false
    ) {
        _text = text
        self.prompt = prompt
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier
        self.leadingButton = leadingButton
        self.autoFocus = autoFocus
    }

    private var isSearching: Bool { isFocused || !text.isEmpty }

    public var body: some View {
        PalGlassContainer(spacing: PalMetrics.searchBarLeadingButtonGap) {
            HStack(spacing: PalMetrics.searchBarLeadingButtonGap) {
                if let leadingButton {
                    glassCircle(
                        systemName: leadingButton.systemName,
                        label: leadingButton.accessibilityLabel,
                        identifier: leadingButton.accessibilityIdentifier,
                        action: leadingButton.action
                    )
                }
                field
                if isSearching {
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
        .padding(.horizontal, PalMetrics.searchBarHorizontalMargin)
        .padding(.top, 8)
        .padding(.bottom, PalMetrics.searchBarBottomPadding)
        .animation(.snappy(duration: 0.2), value: isSearching)
        .task {
            guard autoFocus else { return }
            try? await Task.sleep(for: .milliseconds(150))
            isFocused = true
        }
    }

    private var field: some View {
        HStack(spacing: 10) {
            PalIcon("magnifyingglass")
                .font(.system(size: 19, weight: .regular))
                .accessibilityHidden(true)
            PalTextField(accessibilityLabel, text: $text, prompt: Text(prompt))
                .hermesText(.searchPrompt)
                .foregroundStyle(Color(theme.palette.textPrimary))
                .searchFieldTraits()
                .focused($isFocused)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, minHeight: PalMetrics.searchBarHeight, maxHeight: PalMetrics.searchBarHeight)
        .palGlass(Capsule(), interactive: isFocused)
    }

    private func glassCircle(systemName: String, label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PalIcon(systemName)
                .font(.system(size: 19, weight: .regular))
                .frame(width: PalMetrics.searchBarHeight, height: PalMetrics.searchBarHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .palGlass(Circle())
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

    public var body: some View {
        PalGlassContainer(spacing: PalMetrics.searchBarLeadingButtonGap) {
            HStack(spacing: PalMetrics.searchBarLeadingButtonGap) {
                if let leadingButton {
                    Button(action: leadingButton.action) {
                        PalIcon(leadingButton.systemName)
                            .font(.system(size: 19, weight: .regular))
                            .frame(width: PalMetrics.searchBarHeight, height: PalMetrics.searchBarHeight)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
        .palGlass(Circle())
                    .accessibilityLabel(Text(leadingButton.accessibilityLabel))
                    .accessibilityIdentifier(leadingButton.accessibilityIdentifier)
                }
                Button(action: action) {
                    HStack(spacing: 10) {
                        PalIcon("magnifyingglass")
                            .font(.system(size: 19, weight: .regular))
                        Text(prompt)
                            .hermesText(.searchPrompt)
                            .foregroundStyle(Color(theme.palette.textSecondary))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, minHeight: PalMetrics.searchBarHeight, maxHeight: PalMetrics.searchBarHeight)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .palGlass(Capsule())
                .accessibilityLabel(Text(accessibilityLabel))
                .accessibilityIdentifier(accessibilityIdentifier)
            }
        }
        .padding(.horizontal, PalMetrics.searchBarHorizontalMargin)
        .padding(.top, 8)
        .padding(.bottom, PalMetrics.searchBarBottomPadding)
    }
}
