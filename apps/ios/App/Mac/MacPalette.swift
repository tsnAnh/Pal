#if os(macOS)
import PalDesign
import PalRoster
import SwiftUI

private struct PaletteRow: Identifiable {
    enum Kind {
        case bot(String)
        case message(String)
        case setting(MacSettingsSection)
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String?
}

private struct PaletteSection: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let rows: [PaletteRow]
}

struct MacPalette: View {
    @State private var model: SearchModel
    @State private var selection = 0
    @FocusState private var focused: Bool

    let roster: RosterModel
    let router: AppRouter

    @Environment(MacShell.self) private var shell
    init(roster: RosterModel, router: AppRouter) {
        _model = State(initialValue: SearchModel(roster: roster, supported: router.searchScopes))
        self.roster = roster
        self.router = router
    }

    private var sections: [PaletteSection] {
        var result: [PaletteSection] = []
        let bots: [PaletteRow]
        var messages: [PaletteRow] = []
        if model.isIdleQuery {
            bots = (MacShell.ordered(roster) + roster.hiddenBots).map { PaletteRow(id: "bot-\($0.name)", kind: .bot($0.name), title: $0.displayName, subtitle: $0.preview.text.isEmpty ? nil : $0.preview.text) }
        } else {
            var botRows: [PaletteRow] = []
            for (index, item) in model.items.enumerated() {
                switch item {
                case .bot(let hit):
                    let preview = roster.bot(named: hit.botName)?.preview.text ?? ""
                    botRows.append(PaletteRow(id: SearchView.identifier(of: item), kind: .bot(hit.botName), title: hit.displayName, subtitle: preview.isEmpty ? nil : preview))
                case .message(let hit):
                    messages.append(PaletteRow(id: "\(SearchView.identifier(of: item))-\(index)", kind: .message(hit.botName), title: hit.botDisplayName, subtitle: hit.snippet))
                default:
                    break
                }
            }
            bots = botRows
        }
        if !bots.isEmpty { result.append(PaletteSection(id: "bots", title: "Bots", rows: bots)) }
        if !messages.isEmpty { result.append(PaletteSection(id: "chats", title: "Chats", rows: messages)) }
        let needle = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = MacSettingsSection.allCases.filter { !needle.isEmpty && $0.title.localizedStandardContains(needle) }
        if !settings.isEmpty {
            result.append(PaletteSection(
                id: "settings", title: "Settings",
                rows: settings.map { PaletteRow(id: "setting-\($0.rawValue)", kind: .setting($0), title: $0.title, subtitle: nil) }
            ))
        }
        return result
    }

    private var flatRows: [PaletteRow] { sections.flatMap(\.rows) }

    var body: some View {
        let sections = sections
        let rows = sections.flatMap(\.rows)
        VStack(spacing: 0) {
            searchField
            if rows.isEmpty, !model.isIdleQuery, !model.isLoading {
                Text("No results for “\(model.query)”")
                    .font(.system(size: 13))
                    .foregroundStyle(PalTokens.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                    .accessibilityIdentifier("searchNoResults")
            } else {
                results(sections, rows: rows)
            }
        }
        .frame(width: 590)
        .background(PalTokens.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(PalTokens.panelBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 40, y: 18)
        .background {
            Button("") { router.closeSearch() }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("searchScreen")
        .task { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.query) { selection = 0 }
        .onChange(of: rows.count) { selection = min(selection, max(0, rows.count - 1)) }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(PalTokens.textSecondary)
            TextField("", text: $model.query, prompt: Text("Search Bots, Chats, Settings…").foregroundStyle(PalTokens.textTertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .foregroundStyle(PalTokens.textPrimary)
                .focused($focused)
                .focusEffectDisabled()
                .onSubmit(openSelected)
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.escape) {
                    router.closeSearch()
                    return .handled
                }
                .accessibilityLabel(Text("Search"))
                .accessibilityIdentifier("searchField")
        }
        .padding(.horizontal, 21)
        .frame(height: 60)
        .task {
            for _ in 0..<10 where !focused {
                focused = true
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func results(_ sections: [PaletteSection], rows: [PaletteRow]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(sections) { section in
                        Text(section.title)
                            .font(.system(size: 11))
                            .foregroundStyle(PalTokens.textTertiary)
                            .padding(.horizontal, 11)
                            .padding(.top, 9)
                            .padding(.bottom, 6)
                        ForEach(section.rows) { row in
                            rowView(row, selected: rows.indices.contains(selection) && rows[selection].id == row.id)
                        }
                    }
                    if model.hasFailures {
                        Text("Some results couldn't load.")
                            .font(.system(size: 11))
                            .foregroundStyle(PalTokens.textSecondary)
                            .padding(12)
                            .accessibilityIdentifier("searchPartial")
                    }
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 455)
            .onChange(of: selection) { _, index in
                if rows.indices.contains(index) { proxy.scrollTo(rows[index].id) }
            }
        }
    }

    private func rowView(_ row: PaletteRow, selected: Bool) -> some View {
        Button { open(row) } label: {
            HStack(spacing: 12) {
                leading(row)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .font(.system(size: 13))
                        .foregroundStyle(PalTokens.textPrimary)
                        .lineLimit(1)
                    if let subtitle = row.subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(PalTokens.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13)
            .frame(height: 51)
            .background(selected ? PalTokens.selected : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text([row.title, row.subtitle].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("searchResult-\(row.id)")
        .id(row.id)
    }

    @ViewBuilder
    private func leading(_ row: PaletteRow) -> some View {
        switch row.kind {
        case .bot(let name), .message(let name):
            if let bot = roster.bot(named: name) {
                MacBotAvatar(bot: bot, roster: roster, diameter: 26)
            } else {
                Color.clear.frame(width: 26, height: 26)
            }
        case .setting(let section):
            Image(systemName: section.symbol)
                .font(.system(size: 12))
                .foregroundStyle(PalTokens.textSecondary)
                .frame(width: 26, height: 26)
        }
    }

    private func move(_ offset: Int) -> KeyPress.Result {
        let count = flatRows.count
        guard count > 0 else { return .handled }
        selection = (selection + offset + count) % count
        return .handled
    }

    private func openSelected() {
        let rows = flatRows
        guard rows.indices.contains(selection) else { return }
        open(rows[selection])
    }

    private func open(_ row: PaletteRow) {
        switch row.kind {
        case .bot(let name), .message(let name):
            router.openChat(botName: name)
        case .setting(let section):
            router.closeSearch()
            shell.settingsSection = section
            router.present(.settings)
        }
    }
}
#endif
