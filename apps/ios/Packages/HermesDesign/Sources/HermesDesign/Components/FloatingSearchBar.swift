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

    @Environment(\.hermesTheme) private var theme
    @FocusState private var isFocused: Bool

    public init(
        text: Binding<String>,
        prompt: String = "Search",
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        leadingButton: FloatingSearchBarLeadingButton? = nil
    ) {
        _text = text
        self.prompt = prompt
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier
        self.leadingButton = leadingButton
    }

    private var isSearching: Bool { isFocused || !text.isEmpty }

    private var glass: Glass {
        .regular.tint(Color(theme.palette.glassCapsuleFill).opacity(0.55))
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
        .padding(.horizontal, HermesMetrics.searchBarHorizontalMargin)
        .padding(.vertical, 8)
        .animation(.snappy(duration: 0.2), value: isSearching)
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
