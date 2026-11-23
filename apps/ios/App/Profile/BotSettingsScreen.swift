import PalDesign
import SwiftUI

private struct BotSettingsCloseKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}

private struct BotSettingsSpecKey: EnvironmentKey {
    static let defaultValue: BotAvatarSpec? = nil
}

extension EnvironmentValues {
    var botSettingsSpec: BotAvatarSpec? {
        get { self[BotSettingsSpecKey.self] }
        set { self[BotSettingsSpecKey.self] = newValue }
    }

    var botSettingsClose: @MainActor () -> Void {
        get { self[BotSettingsCloseKey.self] }
        set { self[BotSettingsCloseKey.self] = newValue }
    }
}

struct BotSettingsScreen<Content: View>: View {
    let title: String
    let identifier: String
    var depth = 0
    var spacing: CGFloat = 0
    var back: () -> Void = {}
    @ViewBuilder let content: Content

    @Environment(\.hermesTheme) private var theme
    #if os(macOS)
    @Environment(\.botSettingsClose) private var close
    @Environment(\.botSettingsSpec) private var spec
    #endif

    var body: some View {
        #if os(macOS)
        ScrollView {
            VStack(spacing: spacing) { content }
                .frame(maxWidth: MacLayoutMetrics.settingsColumnWidth)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 32)
        }
        .palSoftScrollEdge(for: .top)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .background(Color(theme.palette.sheetBackground).ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        #else
        ScrollView {
            VStack(spacing: spacing) { content }
                .padding(.top, 16)
                .padding(.bottom, 32)
        }
        .palSoftScrollEdge(for: .top)
        .background(Color(theme.palette.sheetBackground).ignoresSafeArea())
        .accessibilityIdentifier(identifier)
        .palPrincipalToolbarItem {
            Text(title)
                .hermesText(.sheetTitle)
                .foregroundStyle(Color(theme.palette.textPrimary))
                .accessibilityAddTraits(.isHeader)
        }
        .toolbarTitleDisplayMode(.inline)
        #endif
    }

    #if os(macOS)
    private var navigation: BotSettingsNavigation { BotSettingsNavigation(depth: depth) }

    private func perform(_ event: BotSettingsNavigation.Event) {
        switch navigation.exit(for: event) {
        case .back: back()
        case .close: close()
        }
    }

    private var header: some View {
        PalGlassContainer {
            ZStack {
                titlePill
                HStack {
                    if navigation.showsBack {
                        SheetGlassButton(
                            leading: .back, clear: true, escapes: navigation.escapeExit == .back,
                            accessibilityIdentifier: "botSettingsBack"
                        ) { perform(.backButton) }
                    }
                    Spacer(minLength: 0)
                    SheetGlassButton(
                        leading: .close, clear: true, escapes: navigation.escapeExit == .close,
                        accessibilityIdentifier: "botSettingsClose"
                    ) { perform(.closeButton) }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var titlePill: some View {
        HStack(spacing: 8) {
            if let spec { BotAvatarView(spec: spec, size: 18, animated: false) }
            Text(title)
                .hermesText(.sheetTitle)
                .foregroundStyle(Color(theme.palette.textPrimary))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("botSettingsTitle")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .palClearGlass(Capsule(), interactive: false)
    }
    #endif
}

struct BotSettingsBanner: View {
    enum Kind {
        case saved
        case failed
    }

    let kind: Kind
    let text: String
    let identifier: String
    var retry: (() -> Void)?

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            Label(text, palIcon: kind == .saved ? "checkmark.circle.fill" : "exclamationmark.triangle")
                .hermesText(.rowSubtitle)
                .foregroundStyle(Color(theme.palette.textPrimary))
                .accessibilityIdentifier(identifier)
            if let retry {
                Button("Try again", action: retry)
                    .glassButtonStyle()
                    .accessibilityIdentifier("\(identifier)-retry")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind == .failed ? Color(theme.palette.destructive).opacity(0.13) : Color(theme.palette.groupedCard), in: shape)
        .overlay(shape.strokeBorder(kind == .failed ? Color(theme.palette.destructive).opacity(0.45) : Color(theme.palette.cardStroke), lineWidth: 1))
        .padding(.horizontal, PalMetrics.screenMargin)
    }
}
