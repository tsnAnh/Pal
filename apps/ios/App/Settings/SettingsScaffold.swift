import PalDesign
import SwiftUI

struct SettingsPage<Trailing: View, Content: View>: View {
    let title: String
    let identifier: String
    let surface: SheetSurface
    let back: () -> Void
    private let trailing: Trailing
    private let content: Content

    init(
        title: String,
        identifier: String,
        surface: SheetSurface = .grouped,
        back: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.identifier = identifier
        self.surface = surface
        self.back = back
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        SheetChrome(
            title: title, leading: .back, surface: surface, accessibilityIdentifier: identifier, onLeading: back,
            trailing: { trailing },
            content: {
                ScrollView {
                    VStack(alignment: .leading, spacing: PalMetrics.cardGap) { content }
                        .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
        )
    }
}

extension SettingsPage where Trailing == EmptyView {
    init(
        title: String,
        identifier: String,
        surface: SheetSurface = .grouped,
        back: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title: title, identifier: identifier, surface: surface, back: back, trailing: { EmptyView() }, content: content)
    }
}

struct FailureCard: View {
    let message: String
    let identifier: String
    let retry: () -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        SettingsCard(identifier: identifier) {
            VStack(alignment: .leading, spacing: 12) {
                Text(message)
                    .settingsText(.rowTitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again", action: retry)
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("\(identifier)-retry")
            }
            .padding(.horizontal, SettingsSurface.rowInset)
            .padding(.vertical, SettingsSurface.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct LoadingRow: View {
    let title: String
    let identifier: String

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        #if os(macOS)
        MacRow(title: title, identifier: identifier) {
            DelayedReveal { ProgressView().controlSize(.small) }
        }
        #else
        DelayedReveal {
            HStack {
                Text(title)
                    .hermesText(.rowTitle)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                Spacer(minLength: 0)
                ProgressView().tint(Color(theme.palette.textSecondary))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PalMetrics.rowInset)
        }
        .frame(maxWidth: .infinity, minHeight: PalMetrics.rowMinimumHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        #endif
    }
}

enum SettingsHaptics {
    @MainActor
    static func selection() {
        guard UserDefaults.standard.object(forKey: SettingsDefaults.hapticsKey) as? Bool ?? true else { return }
        Haptics.selection()
    }
}

enum SettingsSurface {
    #if os(macOS)
    static let rowInset: CGFloat = 13
    static let rowVerticalPadding: CGFloat = 12
    #else
    static let rowInset = PalMetrics.rowInset
    static let rowVerticalPadding = PalMetrics.rowVerticalPadding
    #endif
}

extension View {
    @ViewBuilder
    func settingsText(_ style: PalTextStyle) -> some View {
        #if os(macOS)
        font(.system(size: style == .rowTitle ? 12 : 11))
        #else
        hermesText(style)
        #endif
    }
}

struct SettingsCard<Content: View>: View {
    let identifier: String
    @ViewBuilder let content: Content

    var body: some View {
        #if os(macOS)
        MacCard(identifier: identifier) { content }
        #else
        GroupedCard(accessibilityIdentifier: identifier) { content }
        #endif
    }
}

struct SettingsCaption: View {
    let text: String
    let identifier: String

    init(_ text: String, identifier: String) {
        self.text = text
        self.identifier = identifier
    }

    var body: some View {
        #if os(macOS)
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(PalTokens.textSecondary)
            .padding(.leading, SettingsSurface.rowInset)
            .accessibilityIdentifier(identifier)
        #else
        SectionCaption(text, accessibilityIdentifier: identifier)
        #endif
    }
}

struct SettingsFootnote: View {
    let text: String
    let identifier: String

    init(_ text: String, identifier: String) {
        self.text = text
        self.identifier = identifier
    }

    var body: some View {
        #if os(macOS)
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(PalTokens.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SettingsSurface.rowInset)
            .accessibilityIdentifier(identifier)
        #else
        CardFootnote(text, accessibilityIdentifier: identifier)
        #endif
    }
}

struct SettingsValueRow: View {
    let title: String
    let value: String?
    var subtitle: String?
    let identifier: String

    init(_ title: String, value: String?, subtitle: String? = nil, identifier: String) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.identifier = identifier
    }

    var body: some View {
        #if os(macOS)
        MacRow(title: title, subtitle: subtitle, identifier: identifier) {
            Text(value ?? "")
                .font(.system(size: 11.5))
                .foregroundStyle(PalTokens.textSecondary)
                .multilineTextAlignment(.trailing)
        }
        #else
        SettingsRow(title: title, subtitle: subtitle, value: value, accessibilityIdentifier: identifier)
        #endif
    }
}

struct SettingsActionRow: View {
    let title: String
    var subtitle: String?
    let identifier: String
    let action: () -> Void

    init(_ title: String, subtitle: String? = nil, identifier: String, action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.identifier = identifier
        self.action = action
    }

    var body: some View {
        #if os(macOS)
        Button(action: action) {
            MacRow(title: title, subtitle: subtitle, identifier: identifier) { EmptyView() }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #else
        SettingsRow(title: title, subtitle: subtitle, trailing: .none, accessibilityIdentifier: identifier, action: action)
        #endif
    }
}

struct SettingsPlaceholderRow: View {
    let text: String
    let identifier: String

    init(_ text: String, identifier: String) {
        self.text = text
        self.identifier = identifier
    }

    var body: some View {
        #if os(macOS)
        MacEmptyRow(text: LocalizedStringKey(text), identifier: identifier)
        #else
        PlaceholderRow(text, accessibilityIdentifier: identifier)
        #endif
    }
}
