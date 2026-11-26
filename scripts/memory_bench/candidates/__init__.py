from __future__ import annotations

import tempfile
from functools import partial
from pathlib import Path

from scripts.memory_bench.candidates import mem0_vector, memory_md
from scripts.memory_bench.candidates.fts import FtsRetriever
from scripts.memory_bench.candidates.isolation import missing_modules
from scripts.memory_bench.candidates.note_store import NoteStore
from scripts.memory_bench.candidates.tiers import PolicyCandidate, Retriever
from scripts.memory_bench.model import CandidateSpec, TokenCounter

FTS_THRESHOLDS = (0.0, 0.1, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 10.0, 12.0, 15.0, 20.0)
VECTOR_THRESHOLDS = (0.0, 0.1, 0.15, 0.175, 0.2, 0.225, 0.25, 0.275, 0.3, 0.325, 0.35, 0.4, 0.45, 0.5, 0.55, 0.6, 0.65, 0.7)

hermes_unavailable = partial(missing_modules, "ruamel")


def _policy(root: Path, retriever: Retriever, count_tokens: TokenCounter, threshold: float | None) -> PolicyCandidate:
    return PolicyCandidate(NoteStore(root / "notes.db"), retriever, count_tokens, threshold)


def build_own_fts(workdir: Path, count_tokens: TokenCounter, threshold: float | None) -> PolicyCandidate:
    root = Path(tempfile.mkdtemp(prefix="own-fts-", dir=workdir))
    return _policy(root, FtsRetriever(root / "fts.db"), count_tokens, threshold)


def _build_mem0(
    hybrid: bool, workdir: Path, count_tokens: TokenCounter, threshold: float | None
) -> PolicyCandidate:
    root = Path(tempfile.mkdtemp(prefix="mem0-", dir=workdir))
    return _policy(root, mem0_vector.Mem0Retriever(root, hybrid), count_tokens, threshold)


REGISTRY: tuple[CandidateSpec, ...] = (
    CandidateSpec(
        "memory_md_reject",
        "Built-in MEMORY.md/USER.md; an add over the character cap is refused",
        memory_md.build_rejecting,
        hermes_unavailable,
    ),
    CandidateSpec(
        "memory_md_prune",
        "Built-in MEMORY.md/USER.md; less salient entries are removed to make room",
        memory_md.build_pruning,
        hermes_unavailable,
    ),
    CandidateSpec(
        "own_fts",
        "Shared tiered note policy with SQLite FTS5 BM25 retrieval",
        build_own_fts,
        hermes_unavailable,
        FTS_THRESHOLDS,
    ),
    CandidateSpec(
        "mem0_vector",
        "Shared tiered note policy; Mem0 infer=False, dense vectors only, local multilingual embedder",
        partial(_build_mem0, False),
        mem0_vector.unavailable,
        VECTOR_THRESHOLDS,
    ),
    CandidateSpec(
        "mem0_hybrid",
        "Shared tiered note policy; Mem0 infer=False, default dense + BM25 ranking, cosine threshold, no spaCy",
        partial(_build_mem0, True),
        mem0_vector.unavailable,
        VECTOR_THRESHOLDS,
    ),
)

__all__ = ["REGISTRY"]
