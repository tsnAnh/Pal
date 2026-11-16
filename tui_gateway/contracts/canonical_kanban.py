"""Read-only Kanban board reads for the native owner app (``gateway/session_kanban_read.py``).

The caller names a board slug (and optionally the gateway it believes it is talking to); it never names a
principal, profile, database path or another gateway. Ids and cursors are qualified by gateway and board,
so a cached value is refused or answered ``snapshot_required`` rather than applied across scopes.
"""
from typing import Literal

from .base import JsonValue, Params, Result
from .registry import canonical_method

class KanbanScope(Result):
    gateway_id: str
    board: str
    board_id: str


class KanbanBoard(Result):
    scope: KanbanScope
    name: str
    description: str
    icon: str
    color: str
    archived: bool
    # ``external`` boards are coordinator-owned: no worker is ever spawned for them.
    dispatch_mode: str
    project_id: str | None = None
    created_at: int | None = None
    # Cards per lifecycle status; null for an archived board, whose database is not read.
    task_counts: dict[str, int] | None = None


class KanbanCard(Result):
    card_id: str
    task_id: str
    title: str
    status: str
    assignee: str | None = None
    priority: int | None = None
    created_at: int | None = None
    started_at: int | None = None
    completed_at: int | None = None
    block_kind: str | None = None
    # The card carries an outcome contract (its completion needs evidence).
    governed: bool


class KanbanPrerequisite(Result):
    """``task_id`` waits for ``requires_task_id`` (a parent-child link is a prerequisite edge, not containment)."""

    task_id: str
    requires_task_id: str


class KanbanReadParams(Params):
    gateway_id: str | None = None


class KanbanBoardParams(KanbanReadParams):
    board: str


class KanbanBoardsListResult(Result):
    gateway_id: str
    boards: list[KanbanBoard]


canonical_method("kanban.boards.list", params=KanbanReadParams, result=KanbanBoardsListResult,
                 doc="Boards with a readable database on this gateway (never creates one). Native owner only.")


class KanbanSnapshotParams(KanbanBoardParams):
    limit: int | None = None
    # ``next_page_token`` of the previous page of this snapshot; omitted for the first page.
    page_token: str | None = None


class KanbanSnapshotResult(Result):
    # ``snapshot_required``: a page token that cannot continue (see ``reason``); restart from the first page.
    state: Literal['present', 'board_absent', 'board_archived', 'snapshot_required']
    # wrong_gateway, wrong_board, stale_generation, invalid_cursor or changed_during_snapshot (the board's
    # event log moved or lost events between pages; no page of the old set may be kept).
    reason: str | None = None
    scope: KanbanScope
    board: KanbanBoard | None = None
    cards: list[KanbanCard] = []
    prerequisites: list[KanbanPrerequisite] = []
    # Cards of this page in task-id order; with ``prerequisites`` for those cards (an edge belongs to its child's page).
    # Non-null while more pages remain: pass it back as ``page_token`` with the same ``limit``.
    next_page_token: str | None = None
    # Only on the final page: the complete card set is then coherent at this cursor. Pass it to
    # ``kanban.events.since``; every event after it is not in the snapshot.
    cursor: str | None = None


canonical_method("kanban.board.snapshot", params=KanbanSnapshotParams, result=KanbanSnapshotResult,
                 doc="One coherent read of a board's cards and the event cursor taken at the same commit.")


class KanbanCardParams(KanbanBoardParams):
    task_id: str


class KanbanCardLifecycle(Result):
    status: str
    assignee: str | None = None
    block_kind: str | None = None
    created_at: int | None = None
    started_at: int | None = None
    completed_at: int | None = None


class KanbanRun(Result):
    run_id: int
    profile: str | None = None
    # ``external`` for a coordinator run (no PID is ever projected); null for a dispatcher run.
    executor: str | None = None
    executor_session: str | None = None
    status: str
    outcome: str | None = None
    started_at: int | None = None
    ended_at: int | None = None
    claim_expires: int | None = None
    last_heartbeat_at: int | None = None
    summary: str | None = None
    error: str | None = None


class KanbanExecution(Result):
    current_run_id: int | None = None
    claim_expires: int | None = None
    runs: list[KanbanRun]


class KanbanOutcomeContract(Result):
    kind: Literal['merged_pr', 'built_artifact', 'installed_app', 'other']
    repo: str | None = None
    name: str | None = None
    required_fields: list[str] = []


class KanbanCiAcceptance(Result):
    """The PR-acceptance gate's own verdict; ``unknown`` when none was recorded. Never a merge or consent claim."""

    state: Literal['accepted', 'pending', 'rejected', 'unknown']
    classification: str | None = None
    run_id: int | None = None
    observed_at: int | None = None
    event_id: int | None = None


class KanbanOutcomeVerification(Result):
    """``verification`` is copied from the stored receipt: ``attested`` (install, other) is never shown as ``independent``."""

    state: Literal['verified', 'refused', 'unknown', 'not_governed']
    verification: Literal['independent', 'attested', 'unknown'] | None = None
    receipt: dict[str, JsonValue] | None = None
    run_id: int | None = None
    observed_at: int | None = None
    event_id: int | None = None


class KanbanProofHistory(Result):
    kind: Literal['pr_acceptance', 'outcome_verified', 'outcome_refused']
    state: str
    verification: Literal['independent', 'attested', 'unknown'] | None = None
    run_id: int | None = None
    observed_at: int | None = None
    event_id: int | None = None


class KanbanEvidence(Result):
    evidence_id: int
    run_id: int
    kind: Literal['execution_ref', 'pr_published', 'pr_merged', 'artifact_built', 'app_installed', 'other_result']
    digest: str
    payload: dict[str, JsonValue]
    producer_profile: str
    producer_session: str | None = None
    # ``github`` and ``local-file`` are checked by the gateway at completion; ``attestation`` is the producer's word.
    source: str
    observed_at: int


class KanbanCardDetail(Result):
    card: KanbanCard
    body: str | None = None
    result: str | None = None
    branch_name: str | None = None
    lifecycle: KanbanCardLifecycle
    execution: KanbanExecution
    outcome_contract: KanbanOutcomeContract | None = None
    # The run the two proofs below refer to: the live run, else the card's latest. Earlier runs' proofs are
    # only in ``proof_history``, never presented as this run's.
    proof_run_id: int | None = None
    ci_acceptance: KanbanCiAcceptance
    outcome_verification: KanbanOutcomeVerification
    proof_history: list[KanbanProofHistory]
    evidence: list[KanbanEvidence]
    prerequisites: list[str]
    dependents: list[str]
    cursor: str


class KanbanCardResult(Result):
    state: Literal['present', 'board_absent', 'board_archived', 'card_absent']
    scope: KanbanScope
    detail: KanbanCardDetail | None = None


canonical_method("kanban.card.get", params=KanbanCardParams, result=KanbanCardResult,
                 doc="One card: lifecycle, execution, CI acceptance, outcome verification and evidence, kept separate.")


class KanbanEvidenceParams(KanbanCardParams):
    run_id: int | None = None


class KanbanEvidenceResult(Result):
    state: Literal['present', 'board_absent', 'board_archived', 'card_absent']
    scope: KanbanScope
    card_id: str | None = None
    evidence: list[KanbanEvidence] = []


canonical_method("kanban.evidence.list", params=KanbanEvidenceParams, result=KanbanEvidenceResult,
                 doc="Immutable evidence receipts of one card, optionally one run, with producer provenance.")


class KanbanEventsParams(KanbanBoardParams):
    # The ``cursor`` of a snapshot or of the previous page of this board; a read without one needs a snapshot.
    cursor: str | None = None
    task_id: str | None = None
    limit: int | None = None


class KanbanEvent(Result):
    event_id: int
    card_id: str
    task_id: str
    run_id: int | None = None
    kind: str
    created_at: int
    # Allowlisted per kind; claim locks, paths and unlisted keys are never present.
    data: dict[str, JsonValue]


class KanbanEventsResult(Result):
    state: Literal['ok', 'snapshot_required', 'board_absent', 'board_archived', 'card_absent']
    scope: KanbanScope
    # Why a snapshot is needed: cursor_required, invalid_cursor, wrong_gateway, wrong_board,
    # stale_generation, ahead_of_log, history_changed (events at or below the cursor were deleted) or
    # gap (an event after the cursor was deleted before it could be replayed).
    reason: str | None = None
    events: list[KanbanEvent] = []
    has_more: bool = False
    # Replays are pure reads: the same cursor returns the same events, and ``event_id`` deduplicates.
    cursor: str | None = None


canonical_method("kanban.events.since", params=KanbanEventsParams, result=KanbanEventsResult,
                 doc="Bounded event replay after a cursor; a cursor that cannot continue answers snapshot_required.")
