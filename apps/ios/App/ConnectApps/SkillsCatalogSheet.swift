import PalConnect
import PalDesign
import SwiftUI

struct SkillsCatalogEntry: View {
    let onOpen: () -> Void

    var body: some View {
        ConnectSectionHeader("Skills", accessibilityIdentifier: "connectAppsSection-skillsCatalog", action: onOpen)
    }
}

struct SkillsCatalogSheet: View {
    @State private var model: SkillsCatalogModel
    let botName: String
    let close: () -> Void

    @Environment(\.hermesTheme) private var theme

    init(model: SkillsCatalogModel, botName: String, close: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.botName = botName
        self.close = close
    }

    var body: some View {
        SheetChrome(
            title: model.detail?.name ?? String(localized: "Skills"),
            leading: model.detail == nil ? .close : .back,
            titleAlignment: .afterLeadingButton,
            accessibilityIdentifier: "skillsCatalog",
            onLeading: { if model.detail == nil { close() } else { model.closeDetail() } },
            trailing: {
                if model.detail == nil, model.updatableCount > 0 {
                    Button(String(localized: "Update all")) { Task { await model.updateAll() } }
                        .disabled(model.isMutating)
                        .accessibilityIdentifier("skillsUpdateAll")
                }
            },
            content: {
                if let row = model.detail { detailPage(row) } else { listPage }
            }
        )
        .task { await model.start() }
        .sheet(item: $model.keyRequest) { request in
            SkillKeyEntrySheet(model: model, request: request, botName: botName)
                .presentationDetents([.medium])
                .macSheetFrame()
        }
        .alert(
            model.removeTarget.map { String(localized: "Remove \($0.name)?") } ?? "",
            isPresented: Binding(get: { model.removeTarget != nil }, set: { if !$0 { model.removeTarget = nil } }),
            presenting: model.removeTarget
        ) { _ in
            Button(String(localized: "Remove"), role: .destructive) { Task { await model.confirmRemove() } }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { _ in
            Text("\(botName) won't be able to use it until you install it again.")
        }
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
            ProgressView().tint(Color(theme.palette.textSecondary)).padding(.top, 60).accessibilityIdentifier("skillsLoading")
        case .unavailable:
            VStack(spacing: 14) {
                Text("Couldn't load skills")
                    .hermesText(.rowTitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                PillButton(String(localized: "Try again"), accessibilityIdentifier: "skillsRetry") { Task { await model.load() } }
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
                PillButton(String(localized: "Show more"), isBusy: model.isLoadingMore, accessibilityIdentifier: "skillsShowMore") {
                    Task { await model.loadMore() }
                }
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
        case .updateAvailable where row.isRemovable: ConnectRowAction(String(localized: "Update"), kind: .accent) { Task { await model.update(row) } }
        case .updateAvailable, .installed: ConnectRowAction(String(localized: "Installed"), kind: .dimmed) { model.openDetail(row) }
        }
    }

    @ViewBuilder
    private var outcomeBanner: some View {
        if let outcome = model.outcome {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: outcome.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(outcome.isSuccess ? Color(theme.palette.toggleOnTrack) : Color(theme.palette.destructive))
                    .accessibilityHidden(true)
                Text(outcome.message)
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.dismissOutcome() } label: { Image(systemName: "xmark") }
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

    private func detailPage(_ row: SkillRow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                outcomeBanner.padding(.horizontal, -ConnectRowMetrics.horizontalMargin)
                detailHeader(row)
                detailContent(row)
                detailActions(row)
            }
            .padding(.horizontal, ConnectRowMetrics.horizontalMargin)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: row.id) { await model.loadDetail() }
        .accessibilityIdentifier("skillDetail")
    }

    private func detailHeader(_ row: SkillRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(stateTitle(row.state))
                .hermesText(.rowSubtitle)
                .foregroundStyle(Color(theme.palette.textSecondary))
                .accessibilityIdentifier("skillDetailState")
            if case .loaded(let detail) = model.detailPhase, !detail.summary.isEmpty {
                Text(detail.summary).hermesText(.rowTitle).foregroundStyle(Color(theme.palette.textPrimary))
            } else if !row.summary.isEmpty {
                Text(row.summary).hermesText(.rowTitle).foregroundStyle(Color(theme.palette.textPrimary))
            }
        }
    }

    private func stateTitle(_ state: SkillState) -> String {
        switch state {
        case .available: String(localized: "Not installed")
        case .installed: String(localized: "Installed")
        case .updateAvailable: String(localized: "Update available")
        }
    }

    @ViewBuilder
    private func detailContent(_ row: SkillRow) -> some View {
        switch model.detailPhase {
        case .loading:
            ProgressView().tint(Color(theme.palette.textSecondary)).frame(maxWidth: .infinity).padding(.top, 20).accessibilityIdentifier("skillDetailLoading")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Text(message).hermesText(.rowTitle).foregroundStyle(Color(theme.palette.textSecondary))
                PillButton(String(localized: "Try again"), accessibilityIdentifier: "skillDetailRetry") { Task { await model.loadDetail() } }
            }
            .accessibilityIdentifier("skillDetailFailed")
            sourceBlock(source: row.source, identifier: row.installTarget, trust: row.trust)
        case .loaded(let detail):
            sourceBlock(source: detail.source ?? row.source, identifier: detail.identifier ?? row.identifier, trust: row.trust)
            if !detail.tags.isEmpty {
                Text(detail.tags.joined(separator: ", "))
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
            }
            requirementsBlock(detail.requirements, row: row)
        }
    }

    private func sourceBlock(source: String?, identifier: String?, trust: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Source").hermesText(.rowTitle).foregroundStyle(Color(theme.palette.textPrimary))
            let parts = [source, trust].compactMap { $0 }.joined(separator: " · ")
            if !parts.isEmpty {
                Text(parts).hermesText(.rowSubtitle).foregroundStyle(Color(theme.palette.textSecondary))
            }
            if let identifier {
                Text(identifier)
                    .hermesText(.rowSubtitle).monospaced()
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("skillDetailSource")
    }

    private func requirementsBlock(_ requirements: SkillRequirements, row: SkillRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Requirements").hermesText(.rowTitle).foregroundStyle(Color(theme.palette.textPrimary))
            if requirements.isEmpty {
                Text("No extra setup needed.")
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
            }
            ForEach(requirements.environment) { key in
                VStack(alignment: .leading, spacing: 3) {
                    Text(key.name)
                        .hermesText(.rowSubtitle).monospaced()
                        .foregroundStyle(Color(theme.palette.chipText))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(theme.palette.chipFill), in: Capsule())
                    let note = [key.prompt, key.isOptional ? String(localized: "Optional") : nil].compactMap { $0 }.joined(separator: " · ")
                    if !note.isEmpty {
                        Text(note).hermesText(.rowSubtitle).foregroundStyle(Color(theme.palette.textSecondary))
                    }
                    if let help = key.help {
                        Text(help).hermesText(.rowSubtitle).foregroundStyle(Color(theme.palette.textSecondary))
                    }
                    if !key.isOptional, row.isInstalled {
                        Button(String(localized: "Add key")) { model.beginKeyEntry(row, keyName: key.name) }
                            .buttonStyle(.pill())
                            .accessibilityLabel(Text("Add key for \(key.name)"))
                            .accessibilityIdentifier("skillAddKey-\(key.name)")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("skillRequirement-\(key.name)")
            }
            if requirements.needsSecrets, !row.isInstalled {
                Text("Install this skill to add the keys \(botName) needs to use it.")
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .accessibilityIdentifier("skillRequirementsNote")
            }
            if !requirements.commands.isEmpty {
                Text("Needs these tools installed on \(botName)'s computer: \(requirements.commands.joined(separator: ", "))")
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .accessibilityIdentifier("skillRequirementCommands")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func detailActions(_ row: SkillRow) -> some View {
        let working = model.isWorking(on: row)
        VStack(spacing: 10) {
            switch row.state {
            case .available:
                PillButton(String(localized: "Install"), kind: .accent, size: .large, isBusy: working, accessibilityIdentifier: "skillInstall") {
                    Task { await model.install(row) }
                }
            case .updateAvailable where row.isRemovable:
                PillButton(String(localized: "Update"), kind: .accent, size: .large, isBusy: working, accessibilityIdentifier: "skillUpdate") {
                    Task { await model.update(row) }
                }
                removeButton(row, working: working)
            case .installed where row.isRemovable, .updateAvailable:
                removeButton(row, working: working)
            case .installed:
                Text("Built in. It can't be removed from here.")
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
            }
        }
        .disabled(model.isMutating && !working)
    }

    @ViewBuilder
    private func removeButton(_ row: SkillRow, working: Bool) -> some View {
        if row.isRemovable {
            PillButton(String(localized: "Remove"), size: .large, isBusy: working, accessibilityIdentifier: "skillRemove") {
                model.removeTarget = row
            }
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
