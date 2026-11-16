import Foundation
import PalKanban
import PalProtocol
import PalTransport
import Testing

/// Failure cases covered here, written before the code under test:
/// - an unknown status, event kind, evidence kind, contract kind, state or verification must decode and display, never throw;
/// - a missing or null verification, evidence list or CI record must read as unknown, never as success;
/// - "Independently verified" only when state is verified and verification is independent;
/// - an attestation is never relabelled independent, and a CI result is never worded as a merge;
/// - claim expiry, digests and receipts never reach the models.
/// Fixture JSON for the four recorded tests comes from the real producer (see KanbanFixtures).
@Suite("Kanban wire decoding")
struct KanbanWireTests {
    private func card(_ json: String) throws -> KanbanCardDetail {
        let result = try #require(KanbanCardResult(KanbanFixtures.json(json)))
        return try #require(result.detail)
    }

    @Test("recorded boards list: gateway scope, external dispatch, archived board without counts")
    func boards() throws {
        let list = try #require(KanbanBoardsList(KanbanFixtures.json(KanbanFixtures.boards)))
        #expect(list.gatewayID == KanbanFixtures.gateway)
        let ops = try #require(list.boards.first { $0.scope.board == "ops" })
        #expect(ops.dispatchMode == "external")
        #expect(ops.scope.boardID == "gw-fixture/ops")
        #expect(ops.count(of: .done) == 2)
        #expect(ops.count(of: .running) == 1)
        let retired = try #require(list.boards.first { $0.scope.board == "retired" })
        #expect(retired.archived)
        #expect(retired.taskCounts == nil)
    }

    @Test("recorded snapshot pages: first has a token and no cursor, last has the cursor and no token")
    func snapshotPages() throws {
        let first = try #require(KanbanSnapshotPage(KanbanFixtures.json(KanbanFixtures.snapshotPage1)))
        let last = try #require(KanbanSnapshotPage(KanbanFixtures.json(KanbanFixtures.snapshotPage2)))
        #expect(first.state == .present)
        #expect(first.nextPageToken != nil)
        #expect(first.cursor == nil)
        #expect(first.cards.count == 4)
        #expect(last.nextPageToken == nil)
        #expect(last.cursor != nil)
        let all = first.cards + last.cards
        #expect(Set(all.map(\.taskID)).count == 5)
        #expect(first.prerequisites + last.prerequisites == [KanbanPrerequisite(taskID: KanbanFixtures.child, requiresTaskID: KanbanFixtures.wip)])
        let governed = all.filter(\.governed).map(\.taskID)
        #expect(Set(governed) == [KanbanFixtures.built, KanbanFixtures.installed, KanbanFixtures.wip])
    }

    @Test("recorded independent proof reads as independently verified, with gateway-checked evidence")
    func independentCard() throws {
        let detail = try card(KanbanFixtures.cardBuilt)
        #expect(KanbanPresentation.outcomeLabel(detail.outcomeVerification) == "Independently verified")
        #expect(detail.proofRunID == 1)
        #expect(detail.execution.runs.map(\.runID) == [1])
        #expect(detail.execution.runs.first?.executor == "external")
        #expect(detail.outcomeContract?.kind == .builtArtifact)
        #expect(detail.evidence.map(\.kind) == [.executionRef, .artifactBuilt])
        #expect(detail.evidence.map { KanbanPresentation.evidenceSource($0.source) } == ["Attested by producer", "Checked by gateway"])
        #expect(detail.evidence.last?.summary == "app.zip")
        #expect(detail.evidence.allSatisfy { $0.producerProfile == "projbot" && $0.producerSession == "sess-1" })
        #expect(KanbanPresentation.ciLabel(detail.ciAcceptance) == "No CI result recorded")
    }

    @Test("recorded attestation is never shown as independent")
    func attestedCard() throws {
        let detail = try card(KanbanFixtures.cardInstalled)
        #expect(detail.outcomeVerification.verification == .attested)
        #expect(KanbanPresentation.outcomeLabel(detail.outcomeVerification) == "Attested by the producer (not independently verified)")
        #expect(detail.outcomeContract?.kind == .installedApp)
    }

    @Test("recorded ungoverned card with a CI acceptance and a running card with no proof")
    func ungovernedAndRunning() throws {
        let plain = try card(KanbanFixtures.cardPlain)
        #expect(KanbanPresentation.outcomeLabel(plain.outcomeVerification) == "No outcome contract")
        #expect(plain.outcomeContract == nil)
        #expect(plain.ciAcceptance.state == .accepted)
        #expect(KanbanPresentation.ciLabel(plain.ciAcceptance) == "CI accepted this pull request head")
        let running = try card(KanbanFixtures.cardWip)
        #expect(running.execution.currentRunID == 3)
        #expect(running.proofRunID == 3)
        #expect(KanbanPresentation.outcomeLabel(running.outcomeVerification) == "Unknown")
        #expect(running.outcomeVerification.verification == nil)
    }

    @Test("recorded evidence list and events page")
    func evidenceAndEvents() throws {
        let evidence = try #require(KanbanEvidenceResult(KanbanFixtures.json(KanbanFixtures.evidenceBuilt)))
        #expect(evidence.state == .present)
        #expect(evidence.evidence.count == 2)
        let events = try #require(KanbanEventsPage(KanbanFixtures.json(KanbanFixtures.eventsAfterSnapshot)))
        #expect(events.state == .ok)
        #expect(events.events.map(\.eventID) == [21, 22])
        #expect(events.events.map(\.kind) == [.prAcceptance, .blocked])
        #expect(events.events.last?.note == "waiting on review")
        #expect(events.hasMore == false)
        #expect(events.cursor != nil)
    }

    @Test("unknown fields, kinds and states decode and stay displayable")
    func tolerance() throws {
        let page = try #require(KanbanSnapshotPage(KanbanFixtures.json("""
        {"state":"present","future_field":{"a":1},"scope":{"gateway_id":"g","board":"b","board_id":"g/b","extra":1},
         "cards":[{"card_id":"g/b/t1","task_id":"t1","title":"x","status":"waiting_on_legal","governed":false,"new":true}],
         "prerequisites":[],"cursor":"c"}
        """)))
        #expect(page.cards.first?.status == .unknown("waiting_on_legal"))
        #expect(KanbanPresentation.statusTitle(.unknown("waiting_on_legal")) == "Waiting on legal")

        let unknownState = try #require(KanbanSnapshotPage(KanbanFixtures.json(#"{"state":"quantum","scope":{"gateway_id":"g","board":"b"}}"#)))
        #expect(unknownState.state == .unknown("quantum"))

        let event = try #require(KanbanEvent(KanbanFixtures.json(#"{"event_id":9,"card_id":"g/b/t1","task_id":"t1","kind":"promoted","created_at":5,"data":{"x":1}}"#)))
        #expect(event.kind == .unknown("promoted"))
        #expect(KanbanPresentation.eventTitle(event.kind) == "Promoted")

        let detail = try card("""
        {"state":"present","scope":{"gateway_id":"g","board":"b","board_id":"g/b"},"detail":{
          "card":{"card_id":"g/b/t1","task_id":"t1","title":"x","status":"done","governed":true},
          "lifecycle":{"status":"done"},"execution":{"runs":[{"run_id":1,"status":"done","claim_expires":99}]},
          "outcome_contract":{"kind":"sealed_envelope"},
          "ci_acceptance":{"state":"maybe"},
          "outcome_verification":{"state":"verified","verification":"notarized"},
          "proof_history":[{"kind":"vibes","state":"strong"}],
          "evidence":[{"evidence_id":1,"run_id":1,"kind":"hologram","digest":"abc","payload":{"pr_url":"https://x"},"producer_profile":"p","source":"carrier-pigeon","observed_at":1}],
          "prerequisites":[],"dependents":[],"cursor":"c"}}
        """)
        #expect(detail.outcomeContract?.kind == .unknown("sealed_envelope"))
        #expect(detail.ciAcceptance.state == .unknown("maybe"))
        #expect(KanbanPresentation.ciLabel(detail.ciAcceptance) == "No CI result recorded")
        #expect(detail.outcomeVerification.verification == .unknown("notarized"))
        #expect(KanbanPresentation.outcomeLabel(detail.outcomeVerification) == "Unknown")
        #expect(detail.proofHistory.first?.kind == .unknown("vibes"))
        #expect(detail.evidence.first?.kind == .unknown("hologram"))
        #expect(detail.evidence.first?.summary == nil)
        #expect(KanbanPresentation.evidenceSource(detail.evidence[0].source) == "carrier-pigeon")
    }

    @Test("missing or null verification, CI and evidence read as unknown, never success")
    func absentProofIsUnknown() throws {
        let detail = try card("""
        {"state":"present","scope":{"gateway_id":"g","board":"b"},"detail":{
          "card":{"card_id":"g/b/t1","task_id":"t1","title":"x","status":"done","governed":true},
          "ci_acceptance":null,"outcome_verification":null,"evidence":null,"proof_history":null}}
        """)
        #expect(KanbanPresentation.outcomeLabel(detail.outcomeVerification) == "Unknown")
        #expect(KanbanPresentation.ciLabel(detail.ciAcceptance) == "No CI result recorded")
        #expect(detail.evidence.isEmpty)
        #expect(detail.proofHistory.isEmpty)
        let verifiedWithoutLabel = KanbanOutcomeVerification(state: .verified, verification: nil)
        #expect(KanbanPresentation.outcomeLabel(verifiedWithoutLabel) == "Unknown")
    }

    @Test("independent wording needs both a verified state and an independent label")
    func independentNeedsBoth() {
        let cases: [(KanbanOutcomeState, KanbanVerification?, String)] = [
            (.verified, .independent, "Independently verified"),
            (.verified, .attested, "Attested by the producer (not independently verified)"),
            (.verified, nil, "Unknown"),
            (.unknown("unknown"), .independent, "Unknown"),
            (.refused, .independent, "Refused"),
            (.notGoverned, .independent, "No outcome contract"),
        ]
        for (state, verification, expected) in cases {
            #expect(KanbanPresentation.outcomeLabel(KanbanOutcomeVerification(state: state, verification: verification)) == expected)
        }
    }

    @Test("CI wording never mentions merge or consent")
    func ciWording() {
        let labels = [KanbanCiState.accepted, .rejected, .unknown("unknown")].map {
            KanbanPresentation.ciLabel(KanbanCiAcceptance(state: $0))
        }
        #expect(labels == ["CI accepted this pull request head", "CI rejected this pull request head", "No CI result recorded"])
        for label in labels {
            #expect(!label.localizedCaseInsensitiveContains("merge"))
            #expect(!label.localizedCaseInsensitiveContains("consent"))
        }
    }

    @Test("cards group by lifecycle in board order, unknown statuses last, counts from task_counts")
    func grouping() throws {
        let board = KanbanBoard(
            scope: KanbanScope(gatewayID: "g", board: "b", boardID: "g/b"), name: "b", taskCounts: ["done": 7, "todo": 2, "weird": 1])
        func make(_ id: String, _ status: KanbanCardStatus) -> KanbanCard {
            KanbanCard(cardID: "g/b/\(id)", taskID: id, title: id, status: status)
        }
        let groups = KanbanPresentation.groups(
            cards: [make("a", .done), make("b", .triage), make("c", .unknown("weird")), make("d", .todo), make("e", .todo)],
            board: board)
        #expect(groups.map(\.status) == [.triage, .todo, .done, .unknown("weird")])
        #expect(groups.map(\.count) == [1, 2, 7, 1])
    }
}
