#if os(macOS)
import HermesDesign
import HermesSettings
import SwiftUI

struct MacCommands: Commands {
    let shell: MacShell
    let roster: RosterModel
    let router: AppRouter
    let connection: ConnectionModel
    let shortcuts: ShortcutStore

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

    private func item(_ shortcut: ShortcutAction, action: @escaping () -> Void) -> some View {
        Button(String(localized: shortcut.localizedTitle)) {
            guard connection.isConnected else { return }
            action()
        }
        .keyboardShortcut(shortcuts.keyboardShortcut(for: shortcut))
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

struct MacShortcutsSheet: View {
    @Environment(ShortcutStore.self) private var store

    private func row(_ action: ShortcutAction, _ title: LocalizedStringKey) -> MacShortcutRow {
        MacShortcutRow(id: action.rawValue, title: title, chords: store.chord(for: action).map { [$0.glyphs] } ?? [])
    }

    private func chords(_ actions: ShortcutAction...) -> [[String]] {
        actions.compactMap { store.chord(for: $0)?.glyphs }
    }

    private var left: [MacShortcutSection] {
        [
            MacShortcutSection(title: "Essentials", rows: [
                MacShortcutRow(id: "search", title: "Search", chords: chords(.search, .searchAlternate)),
                row(.newBot, "New Bot"),
                MacShortcutRow(id: "send", title: "Send", caption: "⇧↩ for new line", chords: [["↩"]]),
                MacShortcutRow(id: "goToBot", title: "Go to Bot", chords: [["⌘", "1–9"]]),
                row(.compactSidebar, "Compact sidebar"),
                row(.settings, "Settings"),
                row(.shortcuts, "Keyboard shortcuts")
            ]),
            MacShortcutSection(title: "Chat", rows: [
                row(.focusComposer, "Focus chat"),
                row(.findInChat, "Find in chat")
            ])
        ]
    }

    private var right: [MacShortcutSection] {
        [
            MacShortcutSection(title: "Navigation", rows: [
                MacShortcutRow(id: "stepBot", title: "Previous / next Bot", chords: chords(.previousBot, .nextBot), joiner: "/")
            ]),
            MacShortcutSection(title: "Panels", rows: [
                row(.details, "Details"),
                row(.connectApps, "Connect apps")
            ]),
            MacShortcutSection(title: "Window", rows: [
                MacShortcutRow(id: "fullScreen", title: "Full screen", chords: [["⌃", "⌘", "F"]])
            ])
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Keyboard shortcuts")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(PalTokens.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 19.5)
                .padding(.bottom, 17)
            HStack(alignment: .top, spacing: 58) {
                column(left)
                column(right)
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
                        ForEach(Array(chord.enumerated()), id: \.offset) { _, glyph in MacKeycap(glyph: glyph) }
                    }
                }
            }
        }
        .frame(height: 31.5)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("shortcut-\(row.id)")
    }
}
#endif
