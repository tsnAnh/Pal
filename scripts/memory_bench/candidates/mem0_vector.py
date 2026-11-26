from __future__ import annotations

import atexit
import logging
import os
import shutil
import tempfile
from collections.abc import Collection
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Any

from scripts.memory_bench.candidates.isolation import missing_modules

EMBED_MODEL = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
EMBED_DIMENSIONS = 384
COLLECTION = "notes"
USER_ID = "memory-bench"
REQUIRED_MODULES = ("mem0", "fastembed", "qdrant_client")
INERT_OPENAI = {"api_key": "inert", "openai_base_url": "http://127.0.0.1:9/v1"}
QUIET_LOGGERS = ("mem0.vector_stores.qdrant", "mem0.utils.spacy_models")


def unavailable() -> str | None:
    return missing_modules(*REQUIRED_MODULES)


class ForbiddenLlm:
    def generate_response(self, *args: Any, **kwargs: Any) -> str:
        raise RuntimeError("mem0 called its LLM although every add uses infer=False")


@dataclass(frozen=True)
class Mem0Runtime:
    memory_class: Any
    embedder: Any


@lru_cache(maxsize=1)
def mem0_runtime() -> Mem0Runtime:
    home = tempfile.mkdtemp(prefix="memory-bench-mem0-")
    atexit.register(shutil.rmtree, home, ignore_errors=True)
    os.environ.update(MEM0_TELEMETRY="false", MEM0_DIR=home, HF_HUB_DISABLE_TELEMETRY="1")
    from mem0 import Memory
    from mem0.configs.embeddings.base import BaseEmbedderConfig
    from mem0.embeddings.fastembed import FastEmbedEmbedding
    from mem0.memory import setup, telemetry

    if telemetry.MEM0_TELEMETRY or setup.mem0_dir != home:
        raise RuntimeError("mem0 was imported before the benchmark disabled telemetry and redirected MEM0_DIR")
    for name in QUIET_LOGGERS:
        logging.getLogger(name).setLevel(logging.ERROR)
    embedder = FastEmbedEmbedding(BaseEmbedderConfig(model=EMBED_MODEL, embedding_dims=EMBED_DIMENSIONS))
    return Mem0Runtime(Memory, embedder)


def create_dense_collection(path: str) -> None:
    from qdrant_client import QdrantClient
    from qdrant_client.models import Distance, VectorParams

    client = QdrantClient(path=path)
    client.create_collection(COLLECTION, vectors_config=VectorParams(size=EMBED_DIMENSIONS, distance=Distance.COSINE))
    client.close()


class Mem0Retriever:
    def __init__(self, root: Path, hybrid: bool) -> None:
        runtime = mem0_runtime()
        path = str(root / "qdrant")
        if not hybrid:
            create_dense_collection(path)
        self._memory = runtime.memory_class.from_config(
            {
                "vector_store": {
                    "provider": "qdrant",
                    "config": {
                        "path": path,
                        "collection_name": COLLECTION,
                        "embedding_model_dims": EMBED_DIMENSIONS,
                        "on_disk": True,
                    },
                },
                "embedder": {
                    "provider": "openai",
                    "config": {**INERT_OPENAI, "embedding_dims": EMBED_DIMENSIONS},
                },
                "llm": {"provider": "openai", "config": dict(INERT_OPENAI)},
                "history_db_path": str(root / "mem0-history.db"),
            }
        )
        self._memory.embedding_model = runtime.embedder
        self._memory.llm = ForbiddenLlm()
        if hybrid and self._memory.vector_store._get_bm25_encoder() is None:
            raise RuntimeError("mem0 hybrid ranking requested but its BM25 encoder did not load")
        self._memory_ids: dict[int, str] = {}

    def add(self, note_id: int, text: str) -> None:
        (added,) = self._memory.add(text, user_id=USER_ID, infer=False)["results"]
        self._memory_ids[note_id] = added["id"]

    def remove(self, note_id: int) -> None:
        self._memory.delete(self._memory_ids.pop(note_id))

    def rank(self, query: str, note_ids: Collection[int]) -> list[tuple[int, float]]:
        if not query.strip() or not self._memory_ids:
            return []
        found = self._memory.search(
            query, filters={"user_id": USER_ID}, top_k=len(self._memory_ids), threshold=0.0, explain=True
        )["results"]
        note_of = {memory_id: note_id for note_id, memory_id in self._memory_ids.items()}
        ranked = ((note_of[hit["id"]], hit["score_details"]["semantic_score"]) for hit in found)
        return [(note_id, score) for note_id, score in ranked if note_id in note_ids]

    def close(self) -> None:
        self._memory.vector_store.client.close()
        self._memory.close()
