import HermesDesign
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
                    VStack(alignment: .leading, spacing: HermesMetrics.cardGap) { content }
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
        GroupedCard(accessibilityIdentifier: identifier) {
            VStack(alignment: .leading, spacing: 12) {
                Text(message)
                    .hermesText(.rowTitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again", action: retry)
                    .buttonStyle(.pill())
                    .accessibilityIdentifier("\(identifier)-retry")
            }
            .padding(.horizontal, HermesMetrics.rowInset)
            .padding(.vertical, HermesMetrics.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct LoadingRow: View {
    let title: String
    let identifier: String

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        HStack {
            Text(title)
                .hermesText(.rowTitle)
                .foregroundStyle(Color(theme.palette.textPrimary))
            Spacer(minLength: 0)
            ProgressView().tint(Color(theme.palette.textSecondary))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, HermesMetrics.rowInset)
        .frame(minHeight: HermesMetrics.rowMinimumHeight)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

enum SettingsHaptics {
    @MainActor
    static func selection() {
        guard UserDefaults.standard.object(forKey: SettingsDefaults.hapticsKey) as? Bool ?? true else { return }
        Haptics.selection()
    }
}
