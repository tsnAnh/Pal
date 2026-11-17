from __future__ import annotations

from fastapi import APIRouter
from fastapi.responses import HTMLResponse
from starlette.concurrency import run_in_threadpool

from gateway.oauth_client_setup import GOOGLE_REDIRECT_PATH, RedirectOutcome
from hermes_cli.web_routers.chat_install import _HEADERS, _PAGE, _RETURN

router = APIRouter()

_PAGES = {
    RedirectOutcome.completed: (200, "Done. Go back to Pal to finish.", _RETURN),
    RedirectOutcome.denied: (200, "Google Workspace isn't connected. Go back to Pal to try again.", _RETURN),
    RedirectOutcome.rejected: (400, "This link has expired or was already used. Go back to Pal and start again.", ""),
}


def _complete(code: str, state: str, error: str) -> RedirectOutcome:
    from gateway.oauth_client_setup import build_store, google_complete
    return google_complete(build_store(), state, code or None, error or None)


@router.get(GOOGLE_REDIRECT_PATH)
async def google_install_callback(code: str = "", state: str = "", error: str = "") -> HTMLResponse:
    try:
        outcome = await run_in_threadpool(_complete, code, state, error)
    except Exception:  # health: allow BLE001 -- the page must not echo anything, any failure reads as an expired link
        outcome = RedirectOutcome.rejected
    status, message, link = _PAGES[outcome]
    return HTMLResponse(_PAGE.format(message=message, link=link), status_code=status, headers=_HEADERS)
