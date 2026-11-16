import PalDesign
import PalKanban
import PalTransport
import SwiftUI

struct KanbanCardView: View {
    let store: KanbanStore
    let board: String
    let taskID: String
    let openCard: (String) -> Void
    let back: () -> Void

    private var detail: KanbanCardDetail? { store.session.detail(board: board, taskID: taskID) }
    private var load: KanbanLoad { store.cardLoad(board: board, taskID: taskID) }

    var body: some View {
        KanbanPage(title: detail?.card.title ?? "Card", identifier: "kanbanCard", back: back, close: nil) {
            content
        }
        .task { await store.loadCard(board: board, taskID: taskID) }
        .refreshable { await store.loadCard(board: board, taskID: taskID) }
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
            case .failed:
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
        lifecycle(detail)
        text("Description", detail.body, identifier: "kanbanBody")
        text("Result", detail.result, identifier: "kanbanResult")
        runs(detail)
        ciAcceptance(detail)
        outcome(detail)
        earlierProofs(detail)
        evidence(detail)
        links("Prerequisites", detail.prerequisites, identifier: "kanbanPrerequisites")
        links("Dependents", detail.dependents, identifier: "kanbanDependents")
        activity
    }

    private func section<Rows: View>(_ title: String, identifier: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
            SectionCaption(title, accessibilityIdentifier: "\(identifier)-caption")
            GroupedCard(accessibilityIdentifier: identifier, content: rows)
        }
    }

    private func lifecycle(_ detail: KanbanCardDetail) -> some View {
        let state = detail.lifecycle
        return section("Lifecycle", identifier: "kanbanLifecycle") {
            SettingsRow.value("Status", value: KanbanPresentation.statusTitle(state.status), accessibilityIdentifier: "kanbanLifecycleStatus")
            if let assignee = state.assignee, !assignee.isEmpty {
                SettingsRow.value("Assignee", value: assignee, accessibilityIdentifier: "kanbanLifecycleAssignee")
            }
            if let kind = state.blockKind, !kind.isEmpty {
                SettingsRow.value("Blocked by", value: kind, accessibilityIdentifier: "kanbanLifecycleBlock")
            }
            if let branch = detail.branchName, !branch.isEmpty {
                SettingsRow.value("Branch", value: branch, accessibilityIdentifier: "kanbanLifecycleBranch")
            }
            if let created = KanbanTime.text(state.createdAt) {
                SettingsRow.value("Created", value: created, accessibilityIdentifier: "kanbanLifecycleCreated")
            }
            if let started = KanbanTime.text(state.startedAt) {
                SettingsRow.value("Started", value: started, accessibilityIdentifier: "kanbanLifecycleStarted")
            }
            if let completed = KanbanTime.text(state.completedAt) {
                SettingsRow.value("Completed", value: completed, accessibilityIdentifier: "kanbanLifecycleCompleted")
            }
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
    private func runs(_ detail: KanbanCardDetail) -> some View {
        if !detail.execution.runs.isEmpty {
            section("Execution runs", identifier: "kanbanRuns") {
                ForEach(detail.execution.runs) { run in
                    SettingsRow.value(
                        runTitle(run, current: detail.execution.currentRunID),
                        value: run.status,
                        subtitle: runSubtitle(run),
                        accessibilityIdentifier: "kanbanRun-\(run.runID)"
                    )
                }
            }
        }
    }

    private func runTitle(_ run: KanbanRun, current: Int?) -> String {
        run.runID == current ? "Run \(run.runID) (live)" : "Run \(run.runID)"
    }

    private func runSubtitle(_ run: KanbanRun) -> String? {
        var parts: [String] = []
        if let profile = run.profile, !profile.isEmpty { parts.append(profile) }
        if let executor = run.executor, !executor.isEmpty { parts.append(executor) }
        if let session = run.executorSession, !session.isEmpty { parts.append("session \(session)") }
        if let outcome = run.outcome, !outcome.isEmpty { parts.append(outcome) }
        if let started = KanbanTime.text(run.startedAt) { parts.append(started) }
        if let summary = run.summary, !summary.isEmpty { parts.append(summary) }
        if let error = run.error, !error.isEmpty { parts.append(error) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func proofCaption(_ title: String, _ detail: KanbanCardDetail) -> String {
        detail.proofRunID.map { "\(title) · run \($0)" } ?? title
    }

    private func ciAcceptance(_ detail: KanbanCardDetail) -> some View {
        let ci = detail.ciAcceptance
        return section(proofCaption("CI acceptance", detail), identifier: "kanbanCi") {
            SettingsRow(
                title: KanbanPresentation.ciLabel(ci),
                subtitle: [ci.classification, KanbanTime.text(ci.observedAt)].compactMap { $0 }.joined(separator: " · ").nonEmpty,
                accessibilityIdentifier: "kanbanCiState"
            )
        }
    }

    private func outcome(_ detail: KanbanCardDetail) -> some View {
        let verification = detail.outcomeVerification
        let contract = detail.outcomeContract.map(KanbanPresentation.contractTitle)
        return section(proofCaption("Outcome verification", detail), identifier: "kanbanOutcome") {
            SettingsRow(
                title: KanbanPresentation.outcomeLabel(verification),
                subtitle: [contract, KanbanTime.text(verification.observedAt)].compactMap { $0 }.joined(separator: " · ").nonEmpty,
                accessibilityIdentifier: "kanbanOutcomeState"
            )
        }
    }

    @ViewBuilder
    private func earlierProofs(_ detail: KanbanCardDetail) -> some View {
        if !detail.proofHistory.isEmpty {
            section("Earlier runs' proofs", identifier: "kanbanProofHistory") {
                ForEach(Array(detail.proofHistory.enumerated()), id: \.offset) { _, proof in
                    SettingsRow(
                        title: KanbanPresentation.proofLabel(proof),
                        subtitle: [proof.runID.map { "Run \($0)" }, KanbanTime.text(proof.observedAt)].compactMap { $0 }.joined(separator: " · ").nonEmpty,
                        accessibilityIdentifier: "kanbanProof-\(proof.eventID ?? 0)"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func evidence(_ detail: KanbanCardDetail) -> some View {
        if !detail.evidence.isEmpty {
            section("Evidence", identifier: "kanbanEvidence") {
                ForEach(detail.evidence) { item in
                    SettingsRow.value(
                        KanbanPresentation.evidenceTitle(item.kind),
                        value: KanbanPresentation.evidenceSource(item.source),
                        subtitle: evidenceSubtitle(item),
                        accessibilityIdentifier: "kanbanEvidence-\(item.evidenceID)"
                    )
                }
            }
        }
    }

    private func evidenceSubtitle(_ item: KanbanEvidence) -> String? {
        var parts: [String] = []
        if !item.producerProfile.isEmpty { parts.append(item.producerProfile) }
        if let session = item.producerSession { parts.append("session \(session)") }
        if let runID = item.runID { parts.append("run \(runID)") }
        if let time = KanbanTime.text(item.observedAt) { parts.append(time) }
        if let summary = item.summary { parts.append(summary) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func links(_ title: String, _ taskIDs: [String], identifier: String) -> some View {
        if !taskIDs.isEmpty {
            section(title, identifier: identifier) {
                ForEach(taskIDs, id: \.self) { id in
                    SettingsRow.navigate(
                        linkedTitle(id), subtitle: id, accessibilityIdentifier: "\(identifier)-\(id)"
                    ) { openCard(id) }
                }
            }
        }
    }

    private func linkedTitle(_ taskID: String) -> String {
        store.session.cache(board)?.cards.values.first { $0.taskID == taskID }?.title ?? taskID
    }

    @ViewBuilder
    private var activity: some View {
        let events = store.events(board: board, taskID: taskID)
        if !events.isEmpty {
            section("Activity", identifier: "kanbanActivity") {
                ForEach(events) { event in
                    SettingsRow.value(
                        KanbanPresentation.eventTitle(event.kind),
                        value: KanbanTime.text(event.createdAt) ?? "",
                        subtitle: event.note,
                        accessibilityIdentifier: "kanbanEvent-\(event.eventID)"
                    )
                }
            }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
