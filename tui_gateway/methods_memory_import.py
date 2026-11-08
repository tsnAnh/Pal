import logging

from .method_ctx import HandlerRegistry, bind_module

logger = logging.getLogger(__name__)
_registry = HandlerRegistry()
method = _registry.method
_profile_scoped = _registry.profile_scoped

_MEMORY_IMPORT_INVALID = 4101
_MEMORY_IMPORT_TOO_LARGE = 4104
_MEMORY_IMPORT_DISABLED = 4105
_MEMORY_IMPORT_FAILED = 5103
_MEMORY_IMPORT_CODES = {
    "invalid_target": _MEMORY_IMPORT_INVALID, "empty": _MEMORY_IMPORT_INVALID,
    "too_large": _MEMORY_IMPORT_TOO_LARGE, "too_many": _MEMORY_IMPORT_TOO_LARGE,
    "disabled": _MEMORY_IMPORT_DISABLED, "write_failed": _MEMORY_IMPORT_FAILED}


@method("memory.import")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from tools.memory_import import MemoryImportError, import_memory_text
    from tools.memory_tool import load_on_disk_store
    try:
        report = import_memory_text(params.get("text"), str(params.get("target") or "user"), load_on_disk_store())
    except MemoryImportError as e:
        return _err(rid, _MEMORY_IMPORT_CODES.get(e.code, _MEMORY_IMPORT_FAILED), str(e))
    except Exception:
        logger.exception("memory.import failed")
        return _err(rid, _MEMORY_IMPORT_FAILED, "Could not import into memory")
    return _ok(rid, {"profile": _bot_settings_profile_name(params), "target": report.target,
                     "candidates": report.candidates, "added": report.added, "duplicates": report.duplicates,
                     "too_long": report.too_long, "blocked": report.blocked, "over_budget": report.over_budget,
                     "usage": report.usage, "entry_count": report.entry_count})


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
