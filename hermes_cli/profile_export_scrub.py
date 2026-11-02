from __future__ import annotations

from pathlib import Path

# Text/config suffixes secret-scrubbed on export; binary DBs, images etc. are left alone.
EXPORT_REDACT_SUFFIXES = frozenset({
    ".md", ".txt", ".yaml", ".yml", ".json", ".jsonl", ".toml", ".ini", ".cfg", ".conf", ".py", ".sh",
    ".bash", ".zsh", ".js", ".ts", ".tsx", ".jsx", ".css", ".html", ".xml", ".csv",
})
# ``Path(".cursorrules").suffix`` is "" — name-match; ``*.env.example`` uses endswith; a hand-named
# config copy (``config.yaml.bak-my-note``) holds config.yaml's secrets under a suffix of its own.
EXPORT_REDACT_NAMES = frozenset({".cursorrules"})


def should_redact_export_file(path: Path) -> bool:
    name = path.name
    return (
        name in EXPORT_REDACT_NAMES
        or name.lower().endswith(".env.example")
        or name.lower().startswith("config.yaml.")
        or path.suffix.lower() in EXPORT_REDACT_SUFFIXES
    )


def scrub_export_secrets(staged: Path) -> None:
    """Force-redact secret-shaped strings in a staged export tree (same pass as ``hermes
    sessions export --redact``). Runs on the staged copy only; symlinks to text files are
    materialized when content changes so redaction never follows a link back into the source."""
    from agent.redact import redact_sensitive_text
    for path in staged.rglob("*"):
        try:
            is_link = path.is_symlink()
            if not path.is_file():  # broken links, symlinked dirs, non-files
                continue
        except OSError:
            continue
        if not should_redact_export_file(path):
            continue
        try:
            text = path.read_text(encoding="utf-8-sig")
        except (UnicodeDecodeError, OSError):
            continue
        redacted = redact_sensitive_text(text, force=True)
        if redacted == text:
            continue
        if is_link:
            path.unlink()
        path.write_text(redacted, encoding="utf-8")
