"""Per-board dispatch mode, persisted in ``board.json``.

``workers`` (default) is upstream behaviour: the dispatcher claims ready cards and spawns
assignee workers. ``external`` marks a coordinator-owned board: cards are claimed, evidenced and
completed by long-lived coordinators through the lifecycle API, and no dispatcher, review,
decomposition or specify path may start a worker for it.
"""
from __future__ import annotations

from typing import Optional

DISPATCH_MODES = ("workers", "external")
DEFAULT_DISPATCH_MODE = "workers"


class ExternalBoardError(ValueError):
    """An operation that would start a worker was attempted on an ``external`` board."""

    def __init__(self, board: str, action: str):
        self.board = board
        self.action = action
        super().__init__(
            f"board {board!r} is coordinator-owned (dispatch_mode=external): {action} would start a "
            "worker. Claim and complete cards through the coordinator path instead."
        )


def validate_dispatch_mode(value: str) -> str:
    if value not in DISPATCH_MODES:
        raise ValueError(f"dispatch_mode must be one of {', '.join(DISPATCH_MODES)}")
    return value


def _slug(board: Optional[str]) -> str:
    from hermes_cli import kanban_db as kb
    return kb._slug_or_default(board) if board else kb.get_current_board()


def board_dispatch_mode(board: Optional[str] = None) -> str:
    from hermes_cli import kanban_db as kb
    mode = kb.read_board_metadata(_slug(board)).get("dispatch_mode")
    return mode if mode in DISPATCH_MODES else DEFAULT_DISPATCH_MODE


def board_spawns_workers(board: Optional[str] = None) -> bool:
    return board_dispatch_mode(board) != "external"


def require_worker_board(board: Optional[str], action: str) -> None:
    if not board_spawns_workers(board):
        raise ExternalBoardError(_slug(board), action)
