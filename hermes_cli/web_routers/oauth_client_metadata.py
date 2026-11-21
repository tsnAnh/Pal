from __future__ import annotations

from pathlib import Path
from urllib.parse import urlsplit

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

from tools.connectors import gateway_client_id
from tools.connectors.mcp_oauth_redirect import CLIENT_METADATA_PATH

router = APIRouter()

_CACHE_SECONDS = 300


def _public_host(home: Path) -> str | None:
    base = gateway_client_id.public_base(home)
    return (urlsplit(base).hostname or "").lower() if base else None


def owning_home(host: str) -> Path | None:
    from hermes_cli.profiles import list_profiles
    from hermes_constants import get_process_hermes_home
    launch = get_process_hermes_home()
    if _public_host(launch) == host:
        return launch
    return next((p.path for p in list_profiles(lazy_skill_count=True) if _public_host(p.path) == host), None)


def _document_for(host: str) -> dict | None:
    home = owning_home(host) if host else None
    return gateway_client_id.document(home) if home is not None else None


@router.get(CLIENT_METADATA_PATH)
async def client_metadata(request: Request) -> JSONResponse:
    document = await run_in_threadpool(_document_for, (request.url.hostname or "").lower())
    if document is None:
        return JSONResponse({"error": "not_found"}, status_code=404, headers={"Cache-Control": "no-store"})
    return JSONResponse(document, headers={"Cache-Control": f"public, max-age={_CACHE_SECONDS}"})
