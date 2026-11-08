import HermesDesign
import HermesRoster
import SwiftUI

struct SearchHost: View {
    @State private var model: SearchModel
    let roster: RosterModel
    let router: AppRouter

    init(roster: RosterModel, router: AppRouter) {
        _model = State(initialValue: SearchModel(roster: roster, supported: router.capabilities.searchScopes))
        self.roster = roster
        self.router = router
    }

    var body: some View {
        SearchView(model: model, roster: roster, router: router)
    }
}

struct SearchView: View {
    @Bindable var model: SearchModel
    let roster: RosterModel
    let router: AppRouter

    @Environment(\.hermesTheme) private var theme

    private var chips: [FilterChipItem<SearchScope>] {
        router.capabilities.searchScopes.map { FilterChipItem(id: $0, title: Self.title(of: $0)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            FilterChipBar(items: chips, selection: $model.scope, accessibilityIdentifier: "searchChips")
                .padding(.top, 4)
                .padding(.bottom, 6)
            results
        }
        .background(Color(theme.palette.canvas).ignoresSafeArea())
        .safeAreaBar(edge: .bottom) {
            FloatingSearchBar(
                text: $model.query,
                accessibilityLabel: String(localized: "Search"),
                accessibilityIdentifier: "searchField",
                trailingButton: FloatingSearchBarLeadingButton(
                    systemName: "xmark",
                    accessibilityLabel: String(localized: "Close search"),
                    accessibilityIdentifier: "searchClose"
                ) { router.closeSearch() },
                autoFocus: true
            )
        }
        .accessibilityIdentifier("searchScreen")
        .task { model.start() }
        .onDisappear { model.stop() }
    }

    @ViewBuilder
    private var results: some View {
        let items = model.items
        if items.isEmpty, !model.isLoading, !model.isIdleQuery {
            ContentUnavailableView.search(text: model.query)
                .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        Button { open(item) } label: {
                            SearchResultRow(item: item, roster: roster)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("searchResult-\(Self.identifier(of: item))")
                    }
                    if model.hasFailures {
                        Text("Some results couldn't load.")
                            .hermesText(.footnoteCaption)
                            .foregroundStyle(Color(theme.palette.textSecondary))
                            .padding(.vertical, 16)
                            .accessibilityIdentifier("searchPartial")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func open(_ item: SearchItem) {
        switch item.destination {
        case .chat(let botName): router.openChat(botName: botName)
        case .groupChat, .file, .routine: break
        }
    }

    static func title(of scope: SearchScope) -> String {
        switch scope {
        case .all: String(localized: "All")
        case .messages: String(localized: "Messages")
        case .bots: String(localized: "Bots")
        case .groupChats: String(localized: "Group Chats")
        case .files: String(localized: "Files")
        case .routines: String(localized: "Routines")
        }
    }

    static func identifier(of item: SearchItem) -> String {
        switch item {
        case .bot(let hit): "bot-\(hit.botName)"
        case .message(let hit): "message-\(hit.botName)"
        case .groupChat(let hit): "group-\(hit.roomID)"
        case .file(let hit): "file-\(hit.itemID)"
        case .routine(let hit): "routine-\(hit.jobID)"
        }
    }
}

private struct SearchResultRow: View {
    let item: SearchItem
    let roster: RosterModel

    @Environment(\.hermesTheme) private var theme

    private var botName: String? {
        switch item.destination {
        case .chat(let name): name
        default: nil
        }
    }

    var body: some View {
        HStack(spacing: 15) {
            if let botName, let bot = roster.bot(named: botName) {
                BotRowAvatar(bot: bot, activity: .idle, mood: .idle, showsPrimaryBadge: false)
            } else {
                Color.clear.frame(width: HermesMetrics.homeRowAvatarSlot, height: HermesMetrics.homeRowAvatarSlot)
            }
            VStack(alignment: .leading, spacing: HermesMetrics.homeRowTextGap) {
                Text(title)
                    .hermesText(.botName)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .hermesText(.botPreview)
                        .foregroundStyle(Color(theme.palette.textSecondary))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text(kindLabel)
                .hermesText(.timestamp)
                .foregroundStyle(Color(theme.palette.textTertiary))
        }
        .padding(.horizontal, HermesMetrics.homeRowInset)
        .frame(minHeight: HermesMetrics.homeRowPitch)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch item {
        case .bot(let hit): hit.displayName
        case .message(let hit): hit.botDisplayName
        case .groupChat(let hit): hit.name
        case .file(let hit): hit.title
        case .routine(let hit): hit.name
        }
    }

    private var subtitle: String? {
        switch item {
        case .bot: nil
        case .message(let hit): hit.snippet
        case .groupChat(let hit): hit.memberNames.joined(separator: ", ")
        case .file(let hit): hit.subtitle
        case .routine(let hit): hit.schedule
        }
    }

    private var kindLabel: String {
        switch item {
        case .bot: String(localized: "Bot")
        case .message(let hit): hit.timestamp.map { RosterTimestamp.label(for: $0) } ?? String(localized: "Message")
        case .groupChat: String(localized: "Group")
        case .file: String(localized: "File")
        case .routine: String(localized: "Routine")
        }
    }
}
