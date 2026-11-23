from __future__ import annotations

import importlib
import json
from pathlib import Path

from evals.proactive_eval.models import Variant

VARIANTS_PATH = Path(__file__).with_name("variants.json")


def _resolve_ref(target: str) -> str:
    module_name, _, attribute = target.partition(":")
    value = importlib.import_module(module_name)
    for part in attribute.split("."):
        value = value[part] if isinstance(value, dict) else getattr(value, part)
    if not isinstance(value, str):
        raise TypeError(f"{target} is not text")
    return value


def load_variants(path: Path = VARIANTS_PATH, *, names: list[str] | None = None) -> list[Variant]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    refs = raw["refs"]

    def text(item: str) -> str:
        return _resolve_ref(refs[item]) if item in refs else item

    variants = [
        Variant(name=v["name"],
                system_text="\n\n".join(text(b) for b in [*v["blocks"], v.get("profile", "")] if b),
                clarify_text=text(v["clarify"]), stub_policy=v.get("stub_policy", ""))
        for v in raw["variants"]]
    if names:
        missing = sorted(set(names) - {v.name for v in variants})
        if missing:
            raise KeyError(f"unknown variants {missing}")
        variants = [next(v for v in variants if v.name == n) for n in names]
    return variants
