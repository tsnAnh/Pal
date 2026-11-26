from __future__ import annotations

import json
import tempfile
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from scripts.memory_bench.candidates.isolation import scoped_hermes_home
from scripts.memory_bench.model import (
    BriefRewrite,
    Injection,
    Kind,
    Loss,
    LossReason,
    Probe,
    Proposal,
    TokenCounter,
    Turn,
)

TARGETS = ("memory", "user")


@dataclass(frozen=True)
class Offer:
    at: float
    target: str
    proposal: Proposal
    refusal: str

    def loss(self, reason: LossReason, detail: str = "") -> Loss:
        return Loss(self.proposal.text, reason, self.at, detail or self.refusal)


@dataclass(frozen=True)
class Ranked:
    salience: float
    said_at: float
    text: str


class MemoryMdCandidate:
    def __init__(self, workdir: Path, on_full: Callable[[MemoryMdCandidate, Offer], None]) -> None:
        self._home = Path(tempfile.mkdtemp(prefix="hermes-home-", dir=workdir)).resolve()
        self._on_full = on_full
        self._ranks: dict[tuple[str, str], Ranked] = {}
        self._losses: list[Loss] = []
        with self._scope():
            self._store = self._load_store()

    @contextmanager
    def _scope(self) -> Iterator[None]:
        with scoped_hermes_home(self._home):
            from hermes_constants import get_hermes_home

            if get_hermes_home().resolve() != self._home:
                raise RuntimeError("get_hermes_home() does not follow HERMES_HOME; refusing to touch another home")
            yield

    def _load_store(self) -> Any:
        from tools.memory_tool import load_on_disk_store

        return load_on_disk_store()

    def _call(self, **arguments: Any) -> dict[str, Any]:
        from tools.memory_tool import memory_tool

        return json.loads(memory_tool(store=self._store, **arguments))

    def write(self, turn: Turn) -> None:
        with self._scope():
            self._store.reset_consolidation_failures()
            for proposal in turn.proposals:
                self._offer(turn, proposal)

    def _offer(self, turn: Turn, proposal: Proposal) -> None:
        target = "user" if turn.owner and proposal.kind is Kind.PREF else "memory"
        outcome = self._call(action="add", target=target, content=proposal.text)
        if outcome["success"]:
            self._remember(target, proposal, turn.at)
            return
        offer = Offer(turn.at, target, proposal, outcome["error"])
        refused_for_room = "current_entries" in outcome or outcome.get("done") is True
        if refused_for_room:
            self._on_full(self, offer)
        else:
            self._losses.append(offer.loss(LossReason.ADMISSION))

    def _remember(self, target: str, proposal: Proposal, at: float) -> None:
        text = proposal.text.strip()
        self._ranks.setdefault((target, text), Ranked(proposal.salience, at, text))

    def reject(self, offer: Offer) -> None:
        self._losses.append(offer.loss(LossReason.REJECTED_FULL))

    def prune(self, offer: Offer) -> None:
        entries = self._store.user_entries if offer.target == "user" else self._store.memory_entries
        beaten = sorted(
            (
                ranked
                for ranked in (self._ranks[offer.target, text] for text in entries)
                if ranked.salience < offer.proposal.salience
            ),
            key=lambda ranked: (ranked.salience, ranked.said_at),
        )
        for count in range(1, len(beaten) + 1):
            victims = beaten[:count]
            operations = [{"action": "remove", "old_text": victim.text} for victim in victims]
            operations.append({"action": "add", "content": offer.proposal.text})
            fits = self._store.resolve_batch_entries(offer.target, operations)["success"]
            self._store.reset_consolidation_failures()
            if fits:
                self._apply_pruning(offer, operations, victims)
                return
        self.reject(offer)

    def _apply_pruning(self, offer: Offer, operations: list[dict[str, str]], victims: list[Ranked]) -> None:
        outcome = self._call(target=offer.target, operations=operations)
        if not outcome["success"]:
            raise RuntimeError(f"memory batch refused after its dry run passed: {outcome['error']}")
        for victim in victims:
            del self._ranks[offer.target, victim.text]
            detail = f"salience={victim.salience:.2f} replaced_by_salience={offer.proposal.salience:.2f}"
            self._losses.append(Loss(victim.text, LossReason.PRUNED, offer.at, detail))
        self._remember(offer.target, offer.proposal, offer.at)

    def end_day(self, day: int) -> None:
        return None

    def inject(self, probe: Probe) -> Injection:
        with self._scope():
            session = self._load_store()
            blocks = (session.format_for_system_prompt(target) for target in TARGETS)
            return Injection(snapshot="\n\n".join(block for block in blocks if block))

    def recall(self, query: Probe) -> str:
        return ""

    def stored_texts(self) -> tuple[str, ...]:
        with self._scope():
            session = self._load_store()
            return (*session.memory_entries, *session.user_entries)

    def losses(self) -> tuple[Loss, ...]:
        return tuple(self._losses)

    def brief_rewrites(self) -> tuple[BriefRewrite, ...]:
        return ()

    def close(self) -> None:
        self._ranks.clear()


def build_rejecting(workdir: Path, count_tokens: TokenCounter, threshold: float | None) -> MemoryMdCandidate:
    return MemoryMdCandidate(workdir, MemoryMdCandidate.reject)


def build_pruning(workdir: Path, count_tokens: TokenCounter, threshold: float | None) -> MemoryMdCandidate:
    return MemoryMdCandidate(workdir, MemoryMdCandidate.prune)
