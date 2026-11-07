from .method_ctx import HandlerRegistry, bind_module

_registry = HandlerRegistry()
method = _registry.method
_profile_scoped = _registry.profile_scoped

_LIBRARY_KIND_FILTERS = {"all": None, "media": "media", "links": "link", "files": "file"}
_LIBRARY_LIST_MAX = 200
_LIBRARY_ASSET_DEFAULT_BYTES = 8_000_000
_LIBRARY_ASSET_HARD_BYTES = 16_000_000


def _library_home(params: dict):
    from pathlib import Path
    if str(params.get("profile") or "").strip():
        return _profile_home(params.get("profile")) or _launch_home()
    from tui_gateway.ws_legacy_fallback import connection_profile_home
    bound = connection_profile_home()
    return Path(bound) if bound else _launch_home()


def _library_open_db(home):
    from pathlib import Path
    if Path(home).resolve() == Path(_launch_home()).resolve():
        db = _get_db()
        return db, False, db is not None
    db_path = Path(home) / "state.db"
    try:
        if db_path.stat().st_size == 0:
            return None, False, True
    except FileNotFoundError:
        return None, False, True
    try:
        from hermes_cli.web_server_sessions import _open_session_db_at_path
        return _open_session_db_at_path(db_path, read_only=True), True, True
    except Exception:
        logger.exception("library store unavailable for %s", home)
        return None, False, False


def _library_close_db(db, owns: bool) -> None:
    if owns and db is not None:
        try:
            db.close()
        except Exception:
            logger.debug("library store close failed", exc_info=True)


def _library_params(rid, model, params: dict):
    from pydantic import ValidationError
    try:
        return model.model_validate(params), None
    except ValidationError:
        return None, _err(rid, 4153, "Invalid library request.")


@method("library.list")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from hermes_state_library import LibraryIndex, parse_cursor
    from tui_gateway.contracts.library import LibraryListParams
    from tui_gateway.library_assets import wire_item
    parsed, problem = _library_params(rid, LibraryListParams, params)
    if problem is not None:
        return problem
    before_us = None
    if parsed.before is not None:
        try:
            before_us = parse_cursor(parsed.before)
        except (ValueError, OverflowError):
            return _err(rid, 4150, "before must be an ISO 8601 timestamp.")
    limit = max(1, min(parsed.limit, _LIBRARY_LIST_MAX))
    home = _library_home(params)
    db, owns, available = _library_open_db(home)
    if not available:
        return _db_unavailable_error(rid, code=5150)
    if db is None:
        return _ok(rid, {"items": [], "next_before": None, "index_complete": True})
    try:
        index = LibraryIndex(home)
        complete = index.refresh(db)
        items, has_more = index.page(
            db, kind=_LIBRARY_KIND_FILTERS[parsed.kind.value], limit=limit, before_us=before_us)
    except Exception:
        logger.exception("library.list failed for %s", home)
        return _err(rid, 5150, "The library could not be loaded right now.")
    finally:
        _library_close_db(db, owns)
    rows = [wire_item(home, item) for item in items]
    return _ok(rid, {"items": rows, "next_before": rows[-1]["occurred_at"] if has_more else None,
                     "index_complete": complete})


@method("library.asset")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from hermes_state_library import LibraryIndex
    from tui_gateway.contracts.library import LibraryAssetParams
    from tui_gateway.library_assets import ASSET_REF_RE, AssetTooLarge, AssetUnavailable, read_asset
    parsed, problem = _library_params(rid, LibraryAssetParams, params)
    if problem is not None:
        return problem
    unknown = _err(rid, 4151, "This item is not available to download.")
    ref = parsed.asset_ref.strip()
    if not ASSET_REF_RE.fullmatch(ref):
        return unknown
    cap = max(1, min(parsed.max_bytes or _LIBRARY_ASSET_DEFAULT_BYTES, _LIBRARY_ASSET_HARD_BYTES))
    home = _library_home(params)
    try:
        item = LibraryIndex(home).lookup(ref)
        if item is None or item.kind == "link":
            return unknown
        db, owns, available = _library_open_db(home)
        if not available or db is None:
            return unknown
        try:
            if item.message_id not in LibraryIndex.live_message_ids(db, [item.message_id]):
                return unknown
        finally:
            _library_close_db(db, owns)
        payload = read_asset(home, item, max_bytes=cap, thumbnail=parsed.thumbnail)
    except AssetUnavailable as exc:
        return _err(rid, 4151, str(exc))
    except AssetTooLarge:
        return _err(rid, 4152, f"This item is larger than the {cap // 1_000_000} MB download limit.")
    except Exception:
        logger.exception("library.asset failed for %s", home)
        return _err(rid, 5151, "The item could not be loaded right now.")
    return _ok(rid, {"mime": payload.mime, "data_base64": payload.data_base64, "size": payload.size})


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
