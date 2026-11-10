#if os(macOS)
import HermesDesign
import SwiftUI

enum MacShortcut: CaseIterable, Identifiable {
    case newBot
    case search
    case searchAlternate
    case goToBot
    case previousBot
    case nextBot
    case compactSidebar
    case details
    case connectApps
    case focusComposer
    case findInChat
    case settings
    case shortcuts

    var id: Self { self }

    var key: KeyEquivalent {
        switch self {
        case .newBot: "n"
        case .search: "k"
        case .searchAlternate: "f"
        case .goToBot: "1"
        case .previousBot: .upArrow
        case .nextBot: .downArrow
        case .compactSidebar: "b"
        case .details: "i"
        case .connectApps: "m"
        case .focusComposer: "l"
        case .findInChat: "f"
        case .settings: ","
        case .shortcuts: "/"
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .searchAlternate, .details, .connectApps: [.command, .shift]
        case .previousBot, .nextBot: .option
        default: .command
        }
    }

    var keyboardShortcut: KeyboardShortcut { KeyboardShortcut(key, modifiers: modifiers) }
}

struct MacCommands: Commands {
    let shell: MacShell
    let roster: RosterModel
    let router: AppRouter
    let connection: ConnectionModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            item(.newBot) { router.present(.createBot) }
        }
        CommandGroup(replacing: .appSettings) {
            item(.settings) { router.present(.settings) }
        }
        CommandGroup(after: .textEditing) {
            Divider()
            item(.findInChat) { shell.beginFind() }
            item(.search) { router.openSearch() }
            item(.searchAlternate) { router.openSearch() }
        }
        CommandGroup(replacing: .sidebar) {
            item(.compactSidebar) { shell.toggleCompact() }
            item(.details) { shell.toggleInspector() }
            item(.connectApps) { router.presentConnectApps() }
        }
        CommandMenu("Bots") {
            item(.previousBot) { step(-1) }
            item(.nextBot) { step(1) }
            Divider()
            ForEach(1...9, id: \.self) { number in
                Button("Go to Bot \(number)") { openBot(at: number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
            }
            Divider()
            item(.focusComposer) { shell.focusComposer() }
        }
        CommandGroup(replacing: .help) {
            item(.shortcuts) { shell.showsShortcuts = true }
        }
    }

    private func item(_ shortcut: MacShortcut, action: @escaping () -> Void) -> some View {
        Button(String(localized: shortcut.menuTitle)) {
            guard connection.isConnected else { return }
            action()
        }
        .keyboardShortcut(shortcut.keyboardShortcut)
    }

    private func openBot(at index: Int) {
        guard connection.isConnected else { return }
        let bots = MacShell.ordered(roster)
        guard bots.indices.contains(index) else { return }
        router.openChat(botName: bots[index].name)
    }

    private func step(_ offset: Int) {
        let bots = MacShell.ordered(roster)
        guard !bots.isEmpty else { return }
        let current = router.currentBotName.flatMap { name in bots.firstIndex { $0.name == name } }
        let next = current.map { ($0 + offset + bots.count) % bots.count } ?? (offset > 0 ? 0 : bots.count - 1)
        router.openChat(botName: bots[next].name)
    }
}

extension MacShortcut {
    var menuTitle: String.LocalizationValue {
        switch self {
        case .newBot: "New Bot"
        case .search: "Search"
        case .searchAlternate: "Search in All Chats"
        case .goToBot: "Go to Bot"
        case .previousBot: "Previous Bot"
        case .nextBot: "Next Bot"
        case .compactSidebar: "Compact Sidebar"
        case .details: "Bot Details"
        case .connectApps: "Connect Apps"
        case .focusComposer: "Focus Message Field"
        case .findInChat: "Find in Chat"
        case .settings: "Settings…"
        case .shortcuts: "Keyboard Shortcuts"
        }
    }
}

private struct MacShortcutRow: Identifiable {
    let id: String
    let title: LocalizedStringKey
    var caption: LocalizedStringKey?
    let chords: [[String]]
    var joiner: LocalizedStringKey = "or"
}

private struct MacShortcutSection: Identifiable {
    let title: LocalizedStringKey
    let rows: [MacShortcutRow]

    var id: String { "\(title)" }
}

extension MacShortcut {
    fileprivate var keycaps: [String] {
        let glyphs = [(EventModifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { modifiers.contains($0.0) }
            .map(\.1)
        let name: String = switch self {
        case .previousBot: "↑"
        case .nextBot: "↓"
        case .goToBot: "1–9"
        case .shortcuts: "/"
        default: String(key.character).uppercased()
        }
        return glyphs + [name]
    }

    fileprivate func row(_ title: LocalizedStringKey) -> MacShortcutRow {
        MacShortcutRow(id: "\(self)", title: title, chords: [keycaps])
    }
}

struct MacShortcutsSheet: View {
    private static let left: [MacShortcutSection] = [
        MacShortcutSection(title: "Essentials", rows: [
            MacShortcutRow(id: "search", title: "Search", chords: [MacShortcut.search.keycaps, MacShortcut.searchAlternate.keycaps]),
            MacShortcut.newBot.row("New Bot"),
            MacShortcutRow(id: "send", title: "Send", caption: "⇧↩ for new line", chords: [["↩"]]),
            MacShortcut.goToBot.row("Go to Bot"),
            MacShortcut.compactSidebar.row("Compact sidebar"),
            MacShortcut.settings.row("Settings"),
            MacShortcut.shortcuts.row("Keyboard shortcuts")
        ]),
        MacShortcutSection(title: "Chat", rows: [
            MacShortcut.focusComposer.row("Focus chat"),
            MacShortcut.findInChat.row("Find in chat")
        ])
    ]

    private static let right: [MacShortcutSection] = [
        MacShortcutSection(title: "Navigation", rows: [
            MacShortcutRow(id: "stepBot", title: "Previous / next Bot", chords: [MacShortcut.previousBot.keycaps, MacShortcut.nextBot.keycaps], joiner: "/")
        ]),
        MacShortcutSection(title: "Panels", rows: [
            MacShortcut.details.row("Details"),
            MacShortcut.connectApps.row("Connect apps")
        ]),
        MacShortcutSection(title: "Window", rows: [
            MacShortcutRow(id: "fullScreen", title: "Full screen", chords: [["⌃", "⌘", "F"]])
        ])
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Keyboard shortcuts")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(PalTokens.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 19.5)
                .padding(.bottom, 17)
            HStack(alignment: .top, spacing: 58) {
                column(Self.left)
                column(Self.right)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 29)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shortcutsContent")
    }

    private func column(_ sections: [MacShortcutSection]) -> some View {
        VStack(alignment: .leading, spacing: 19) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.title)
                        .font(.system(size: 12))
                        .foregroundStyle(PalTokens.textPrimary)
                        .frame(height: 16)
                    VStack(spacing: 0) {
                        ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                            rowView(row)
                                .overlay(alignment: .bottom) {
                                    if index < section.rows.count - 1 { PalHairline(color: PalTokens.hairline) }
                                }
                        }
                    }
                }
            }
        }
        .frame(width: 354, alignment: .topLeading)
    }

    private func rowView(_ row: MacShortcutRow) -> some View {
        HStack(spacing: 8) {
            Text(row.title)
                .font(.system(size: 13))
                .foregroundStyle(PalTokens.textPrimary)
            if let caption = row.caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(PalTokens.textTertiary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                ForEach(Array(row.chords.enumerated()), id: \.offset) { index, chord in
                    if index > 0 {
                        Text(row.joiner).font(.system(size: 10)).foregroundStyle(PalTokens.textTertiary)
                    }
                    HStack(spacing: 2) {
                        ForEach(Array(chord.enumerated()), id: \.offset) { _, glyph in keycap(glyph) }
                    }
                }
            }
        }
        .frame(height: 31.5)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("shortcut-\(row.id)")
    }

    private func keycap(_ glyph: String) -> some View {
        Text(glyph)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(PalTokens.textSecondary)
            .padding(.horizontal, 4)
            .frame(minWidth: 19, minHeight: 19)
            .background(PalTokens.control, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
#endif
