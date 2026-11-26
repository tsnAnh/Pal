from __future__ import annotations

import os
from collections.abc import Iterator
from contextlib import contextmanager
from importlib.util import find_spec
from pathlib import Path

RUN_COMMAND = (
    "uv run --no-config --no-project --isolated --python 3.12 "
    "--with-requirements scripts/memory_bench/requirements.txt python -m scripts.memory_bench"
)


def missing_modules(*modules: str) -> str | None:
    missing = [name for name in modules if find_spec(name) is None]
    if not missing:
        return None
    return f"missing Python packages: {', '.join(missing)}; run the benchmark with: {RUN_COMMAND}"


@contextmanager
def scoped_hermes_home(home: Path) -> Iterator[None]:
    previous = os.environ.get("HERMES_HOME")
    os.environ["HERMES_HOME"] = str(home)
    try:
        yield
    finally:
        if previous is None:
            del os.environ["HERMES_HOME"]
        else:
            os.environ["HERMES_HOME"] = previous
