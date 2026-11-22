"""``GET /webapp/mcp-oauth/callback``: where an MCP server's authorization page redirects the browser when the
Pal app asked for the gateway's https return. The one-use ``state`` is the credential, so the route is public
at the sign-in gate like the chat-install callback. It answers a static page that sends the browser back into
the app; the code, the state and any provider text never come back out.
"""

from __future__ import annotations

from fastapi import APIRouter
from fastapi.responses import HTMLResponse
from starlette.concurrency import run_in_threadpool

from tools.connectors.app_scheme import AppScheme
from tools.connectors.mcp_oauth_redirect import GATEWAY_CALLBACK_PATH, app_done_url

router = APIRouter()

_HEADERS = {"Cache-Control": "no-store", "Referrer-Policy": "no-referrer"}
_PAGE = ('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
         '<meta http-equiv="refresh" content="0;url={link}"><title>Pal</title>'
         '<body style="font-family:-apple-system,system-ui,sans-serif;margin:3rem 1.5rem">'
         '<p>{message}</p><p><a href="{link}">Return to Pal</a></p>')
_DONE = (200, "Done. Go back to Pal to finish.")
_DENIED = (200, "Sign-in was not completed. Go back to Pal to try again.")
REJECTED_MESSAGE = "This link has expired or was already used. Go back to Pal and start again."
_REJECTED = (400, REJECTED_MESSAGE)


def _deliver(code: str, state: str, error: str, iss: str, description: str) -> AppScheme | None:
    from tui_gateway.mcp_oauth_sessions import deliver_gateway_callback
    return deliver_gateway_callback(
        state, code=code or None, error=error or None, iss=iss or None, error_description=description or None)


@router.get(GATEWAY_CALLBACK_PATH)
async def mcp_oauth_callback(
    code: str = "", state: str = "", error: str = "", iss: str = "", error_description: str = ""
) -> HTMLResponse:
    try:
        delivered = await run_in_threadpool(_deliver, code, state, error, iss, error_description) if state else None
    except Exception:  # health: allow BLE001 -- the page must not echo anything, any failure reads as an expired link
        delivered = None
    status, message = _REJECTED if delivered is None else _DENIED if error else _DONE
    link = app_done_url(delivered or AppScheme.release)
    return HTMLResponse(_PAGE.format(message=message, link=link), status_code=status, headers=_HEADERS)
