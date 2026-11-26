from __future__ import annotations

from scripts.memory_bench.model import TokenCounter

ENCODING = "cl100k_base"


def cl100k_counter() -> TokenCounter:
    import tiktoken

    encoding = tiktoken.get_encoding(ENCODING)
    return lambda text: len(encoding.encode(text, disallowed_special=()))
