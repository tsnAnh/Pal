import PalDesign
import PalKanban
import PalTransport
import SwiftUI

extension KanbanCardView {
    func lifecycle(_ detail: KanbanCardDetail) -> some View {
        let state = detail.lifecycle
        return section("Lifecycle", identifier: "kanbanLifecycle") {
            SettingsRow.value("Status", value: KanbanPresentation.statusTitle(state.status), accessibilityIdentifier: "kanbanLifecycleStatus")
            if let assignee = state.assignee, !assignee.isEmpty {
                SettingsRow.value("Assignee", value: roster.names.name(for: assignee) ?? assignee, accessibilityIdentifier: "kanbanLifecycleAssignee")
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
    func runs(_ detail: KanbanCardDetail) -> some View {
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
        if let profile = roster.names.name(for: run.profile) { parts.append(profile) }
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

    func ciAcceptance(_ detail: KanbanCardDetail) -> some View {
        let ci = detail.ciAcceptance
        return section(proofCaption("CI acceptance", detail), identifier: "kanbanCi") {
            SettingsRow(
                title: KanbanPresentation.ciLabel(ci),
                subtitle: [ci.classification, KanbanTime.text(ci.observedAt)].compactMap { $0 }.joined(separator: " · ").nonEmpty,
                accessibilityIdentifier: "kanbanCiState"
            )
        }
    }

    func outcome(_ detail: KanbanCardDetail) -> some View {
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
    func earlierProofs(_ detail: KanbanCardDetail) -> some View {
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
    func links(_ title: String, _ taskIDs: [String], identifier: String) -> some View {
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
    var activity: some View {
        let events = store.events(board: board, taskID: taskID)
        if !events.isEmpty {
            section("Timeline", identifier: "kanbanActivity") {
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

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
