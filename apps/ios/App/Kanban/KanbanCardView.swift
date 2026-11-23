import PalDesign
import PalKanban
import PalTransport
import SwiftUI

struct KanbanCardView: View {
    enum Mode {
        case page
        case pane
    }

    let store: KanbanStore
    let board: String
    let taskID: String
    var mode: Mode = .page
    let openCard: (String) -> Void
    let back: () -> Void

    @Environment(\.kanbanRoster) var roster
    @State private var showsAllEvidence = false

    private var detail: KanbanCardDetail? { store.session.detail(board: board, taskID: taskID) }
    private var load: KanbanLoad { store.cardLoad(board: board, taskID: taskID) }
    private var title: String {
        guard let detail else { return String(localized: "Card") }
        return KanbanCardRow(card: detail.card, project: nil, detail: detail).displayTitle
    }

    var body: some View {
        Group {
            switch mode {
            case .page:
                KanbanPage(title: title, identifier: "kanbanCard", back: back, close: nil) { content }
            case .pane:
                pane
            }
        }
        .task(id: taskID) { await store.loadCard(board: board, taskID: taskID) }
        .onChange(of: taskID) { showsAllEvidence = false }
        .refreshable { await store.loadCard(board: board, taskID: taskID) }
    }

    private var pane: some View {
        SheetChrome(
            surface: .canvas,
            headerStyle: .toolbarRow,
            escapes: false,
            accessibilityIdentifier: "kanbanCard",
            leadingAccessibilityIdentifier: "kanbanCard-close",
            onLeading: back
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: PalMetrics.cardGap) {
                    Text(title)
                        .hermesText(.rowTitle)
                        .foregroundStyle(PalTokens.textPrimary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, PalMetrics.screenMargin)
                        .accessibilityAddTraits(.isHeader)
                    content
                }
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var content: some View {
        if let detail {
            if load == .failed { failure }
            sections(detail)
        } else {
            switch load {
            case .idle, .loading, .ready:
                LoadingRow(title: "Loading card", identifier: "kanbanCardLoading")
            case .failed, .unreachable:
                failure
            default:
                KanbanUnavailable(load: load)
            }
        }
    }

    private var failure: some View {
        FailureCard(message: KanbanLoad.failed.message ?? "", identifier: "kanbanCardFailure") {
            Task { await store.loadCard(board: board, taskID: taskID) }
        }
    }

    @ViewBuilder
    private func sections(_ detail: KanbanCardDetail) -> some View {
        let row = cardRow(detail)
        let document = KanbanBody.parse(detail.body, title: row.displayTitle)
        header(row)
        ticket(document)
        text("Result", detail.result, identifier: "kanbanResult")
        evidence(detail)
        activity
        lifecycle(detail)
        runs(detail)
        ciAcceptance(detail)
        outcome(detail)
        earlierProofs(detail)
        links("Prerequisites", detail.prerequisites, identifier: "kanbanPrerequisites")
        links("Dependents", detail.dependents, identifier: "kanbanDependents")
    }

    private func cardRow(_ detail: KanbanCardDetail) -> KanbanCardRow {
        KanbanCardRow(card: detail.card, project: store.session.cache(board)?.board?.projectID, detail: detail)
    }

    private func header(_ row: KanbanCardRow) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            KanbanBadges(row: row, now: context.date)
        }
        .padding(.horizontal, PalMetrics.screenMargin)
    }

    private var knownRefs: [String: String] {
        KanbanRef.index(rows: KanbanBoardLayout.rows(session: store.session, board: board))
            .filter { $0.value != taskID }
    }

    @ViewBuilder
    private func ticket(_ document: KanbanBodyDocument) -> some View {
        if !document.isEmpty {
            let refs = knownRefs
            VStack(alignment: .leading, spacing: PalMetrics.cardGap) {
                if !document.intro.isEmpty {
                    GroupedCard(accessibilityIdentifier: "kanbanBodyIntro") {
                        KanbanBodyView(blocks: document.intro, refs: refs, openCard: openCard)
                    }
                }
                ForEach(document.parts) { part in
                    ticketPart(part, refs: refs)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("kanbanBody")
        }
    }

    private func ticketPart(_ part: KanbanBodyPart, refs: [String: String]) -> some View {
        section(part.label.title, identifier: "kanbanPart-\(part.label.identifier)") {
            if !part.blocks.isEmpty {
                KanbanBodyView(blocks: part.blocks, refs: refs, openCard: openCard)
            }
            ForEach(Array(part.links.enumerated()), id: \.offset) { index, url in
                let pullRequest = KanbanPresentation.pullRequestRow(url)
                SettingsRow(
                    title: pullRequest.title,
                    subtitle: pullRequest.subtitle,
                    trailing: .external,
                    accessibilityIdentifier: "kanbanPullRequestLink-\(index)"
                ) { ExternalLink.open(url) }
            }
        }
    }

    func section<Rows: View>(_ title: String, identifier: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
            SectionCaption(title, accessibilityIdentifier: "\(identifier)-caption")
            GroupedCard(accessibilityIdentifier: identifier, content: rows)
        }
    }

    @ViewBuilder
    private func text(_ title: String, _ value: String?, identifier: String) -> some View {
        if let value, !value.isEmpty {
            section(title, identifier: identifier) {
                Text(value)
                    .hermesText(.rowSubtitle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, PalMetrics.rowInset)
                    .padding(.vertical, PalMetrics.rowVerticalPadding)
            }
        }
    }

    @ViewBuilder
    private func evidence(_ detail: KanbanCardDetail) -> some View {
        let groups = KanbanEvidenceGroup.groups(detail.evidence)
        if !groups.isEmpty {
            let hidden = showsAllEvidence ? 0 : max(groups.count - KanbanEvidenceGroup.visibleLimit, 0)
            section("Evidence", identifier: "kanbanEvidence") {
                ForEach(showsAllEvidence ? groups : Array(groups.prefix(KanbanEvidenceGroup.visibleLimit))) { group in
                    evidenceRow(group)
                }
                if hidden > 0 {
                    HStack {
                        Button("Show all \(groups.count)") { showsAllEvidence = true }
                            .glassButtonStyle()
                            .accessibilityIdentifier("kanbanEvidenceShowAll")
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, PalMetrics.rowInset)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func evidenceRow(_ group: KanbanEvidenceGroup) -> SettingsRow {
        let detail = group.url.map { KanbanPresentation.pullRequestRow($0).title } ?? group.summary
        let last = KanbanTime.text(group.latest.observedAt).map { String(localized: "last \($0)") }
        let subtitle = [detail, last].compactMap { $0 }.joined(separator: " · ").nonEmpty
        var open: (() -> Void)?
        if let url = group.url { open = { ExternalLink.open(url) } }
        return SettingsRow(
            title: KanbanPresentation.evidenceTitle(group.kind),
            subtitle: subtitle,
            value: "\u{00D7}\(group.count)",
            trailing: group.url == nil ? .none : .external,
            accessibilityIdentifier: "kanbanEvidence-\(group.latest.evidenceID)",
            action: open
        )
    }
}
