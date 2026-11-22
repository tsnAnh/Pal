import PalConnect
import PalDesign
import SwiftUI

struct SkillsCatalogEntry: View {
    let onOpen: () -> Void

    var body: some View {
        #if os(macOS)
        ConnectSectionHeader("Skills", accessibilityIdentifier: "connectAppsSection-skillsCatalog", action: onOpen)
        #else
        ConnectFlatSectionHeader(title: String(localized: "Skills"), identifier: "connectAppsSection-skillsCatalog", action: onOpen)
        #endif
    }
}

struct SkillsCatalogSheet: View {
    @State var model: SkillsCatalogModel
    let botName: String
    let close: () -> Void

    @Environment(\.hermesTheme) var theme
    #if os(iOS)
    @State private var shownDetail: SkillRow?

    private var showsDetail: Binding<Bool> {
        Binding(
            get: { model.detail != nil },
            set: { if !$0, model.detail != nil { model.closeDetail() } }
        )
    }
    #endif

    init(model: SkillsCatalogModel, botName: String, close: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.botName = botName
        self.close = close
    }

    var body: some View {
        page
        .task { await model.start() }
        .macSheet(item: $model.keyRequest) { request in
            SkillKeyEntrySheet(model: model, request: request,
                               botName: botName)
                .presentationDetents([.medium])
        }
        .macAlert(item: $model.removeTarget) { target in
            MacDialogContent(
                String(localized: "Remove \(target.name)?"),
                message: String(localized: "\(botName) won't be able to use it until you install it again."),
                actions: [
                    MacDialogAction(String(localized: "Remove"), role: .destructive) { Task { await model.confirmRemove() } },
                    MacDialogAction(String(localized: "Cancel"), role: .cancel),
                ]
            )
        }
    }

    @ViewBuilder
    private var page: some View {
        #if os(iOS)
        NavigationStack {
            listChrome
                .environment(\.sheetChromeHostedInNavigation, true)
                .navigationDestination(isPresented: showsDetail) {
                    if let row = model.detail ?? shownDetail {
                        detailChrome(row)
                            .environment(\.sheetChromeHostedInNavigation, true)
                    }
                }
        }
        .tint(.primary)
        .onChange(of: model.detail?.id, initial: true) {
            if let row = model.detail { shownDetail = row }
        }
        #else
        if let row = model.detail { detailChrome(row) } else { listChrome }
        #endif
    }

    private var listChrome: some View {
        SheetChrome(
            title: String(localized: "Skills"),
            titleAlignment: .afterLeadingButton,
            accessibilityIdentifier: "skillsCatalog",
            onLeading: close,
            trailing: {
                if model.updatableCount > 0 {
                    Button(String(localized: "Update all")) { Task { await model.updateAll() } }
                        .disabled(model.isMutating)
                        .accessibilityIdentifier("skillsUpdateAll")
                }
            },
            content: { listPage }
        )
    }

    private func detailChrome(_ row: SkillRow) -> some View {
        SheetChrome(
            title: row.name,
            leading: .back,
            titleAlignment: .afterLeadingButton,
            accessibilityIdentifier: "skillsCatalog",
            onLeading: { model.closeDetail() },
            content: { detailPage(row) }
        )
    }

    private var listPage: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                outcomeBanner
                FilterChipBar(items: chipItems, selection: $model.filter, accessibilityIdentifier: "skillsFilters")
                listBody
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.automatic)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaBar(edge: .bottom) {
            FloatingSearchBar(
                text: $model.query,
                prompt: String(localized: "Search skills"),
                accessibilityLabel: String(localized: "Search skills"),
                accessibilityIdentifier: "skillsSearch"
            )
        }
        .task(id: model.query) {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await model.runSearch()
        }
    }

    private var chipItems: [FilterChipItem<SkillFilter>] {
        [
            FilterChipItem(id: .all, title: String(localized: "All")),
            FilterChipItem(id: .installed, title: String(localized: "Installed")),
            FilterChipItem(
                id: .updates,
                title: model.updatableCount > 0 ? String(localized: "Updates (\(model.updatableCount))") : String(localized: "Updates")
            ),
        ]
    }

    @ViewBuilder
    private var listBody: some View {
        switch model.phase {
        case .loading:
            DelayedProgressView().tint(Color(theme.palette.textSecondary)).padding(.top, 60).accessibilityIdentifier("skillsLoading")
        case .unavailable:
            VStack(spacing: 14) {
                Text("Couldn't load skills")
                    .hermesText(.rowTitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                Button { Task { await model.load() } } label: { Text("Try again") }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("skillsRetry")
            }
            .padding(.top, 60)
            .accessibilityIdentifier("skillsUnavailable")
        case .ready:
            let rows = model.rows
            if rows.isEmpty {
                Text(emptyText)
                    .hermesText(.rowTitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .multilineTextAlignment(.center)
                    .padding(.top, 60)
                    .accessibilityIdentifier("skillsEmpty")
            }
            ForEach(rows) { skillRow($0) }
            if model.canLoadMore {
                Button { Task { await model.loadMore() } } label: {
                    HStack(spacing: 6) {
                        if model.isLoadingMore { ProgressView().controlSize(.small) }
                        Text("Show more")
                    }
                }
                .buttonStyle(.glass)
                .disabled(model.isLoadingMore)
                .accessibilityIdentifier("skillsShowMore")
                .padding(.top, 16)
            }
        }
    }

    private var emptyText: String {
        if !model.trimmedQuery.isEmpty { return String(localized: "No matches") }
        switch model.filter {
        case .all: return String(localized: "No skills available")
        case .installed: return String(localized: "No skills installed yet")
        case .updates: return String(localized: "Every skill is up to date")
        }
    }

    private func skillRow(_ row: SkillRow) -> some View {
        ConnectAppRow(
            title: row.name, summary: row.summary.isEmpty ? (row.source ?? "") : row.summary,
            accessibilityIdentifier: "skill-\(row.id)", isBusy: model.isWorking(on: row), trailing: rowAction(row)
        ) { PluginGlyphTile() }
        .contentShape(Rectangle())
        .onTapGesture { model.openDetail(row) }
        .accessibilityAction(named: Text("Show details")) { model.openDetail(row) }
    }

    private func rowAction(_ row: SkillRow) -> ConnectRowAction {
        switch row.state {
        case .available: ConnectRowAction(String(localized: "Install")) { Task { await model.install(row) } }
        case .updateAvailable where row.isRemovable: ConnectRowAction(String(localized: "Update"), prominent: true) { Task { await model.update(row) } }
        case .updateAvailable, .installed: ConnectRowAction(String(localized: "Installed")) { model.openDetail(row) }
        }
    }

    @ViewBuilder
    var outcomeBanner: some View {
        if let outcome = model.outcome {
            HStack(alignment: .top, spacing: 10) {
                PalIcon(outcome.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        ink: outcome.isSuccess ? .success : .destructive)
                    .accessibilityHidden(true)
                Text(outcome.message)
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.dismissOutcome() } label: { PalIcon("xmark", ink: .secondary) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .accessibilityLabel(Text("Dismiss"))
                    .accessibilityIdentifier("skillsOutcomeDismiss")
            }
            .padding(14)
            .background(Color(theme.palette.groupedCard), in: RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
            .padding(.horizontal, ConnectRowMetrics.horizontalMargin)
            .padding(.bottom, 10)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(outcome.isSuccess ? "skillsSuccess" : "skillsFailure")
        }
    }
}

struct SkillKeyEntrySheet: View {
    let model: SkillsCatalogModel
    let request: SkillsCatalogModel.KeyRequest
    let botName: String

    var body: some View {
        SecretEntryView(
            connectorName: request.skill,
            accountLabel: botName,
            purpose: String(localized: "Paste the key for \(request.keyName). It is saved for \(botName) only and can't be read back."),
            fieldLabel: request.keyName,
            state: model.keyState,
            identifiers: SecretEntryIdentifiers(
                field: "skill-key-field", submit: "skill-key-save-button",
                cancel: "skill-key-cancel-button", status: "skill-key-status"
            ),
            onSubmit: { value in Task { await model.submitKey(value) } },
            onCancel: { model.cancelKeyEntry() }
        )
        .padding(24)
    }
}
