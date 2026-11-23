"""``GET /webapp/chat-install/callback``: where a chat provider (Slack first) redirects the browser after
the owner clicks Allow. The one-use ``state`` is the credential, so the route is public at the sign-in gate
like the gateway-connections callback. It answers a static page only: the code, the state and any provider
text never come back out.
"""

from __future__ import annotations

from fastapi import APIRouter
from fastapi.responses import HTMLResponse
from starlette.concurrency import run_in_threadpool

from gateway.chat_install_service import RedirectOutcome
from tools.connectors.app_scheme import AppScheme
from tui_gateway.chat_install import REDIRECT_PATH

router = APIRouter()

_HEADERS = {"Cache-Control": "no-store", "Referrer-Policy": "no-referrer"}
_PAGE = ('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
         '<title>Pal</title><body style="font-family:-apple-system,system-ui,sans-serif;margin:3rem 1.5rem">'
         '<p>{message}</p>{link}')
_RETURN = '<p><a href="{link}">Return to Pal</a></p>'
_PAGES = {
    RedirectOutcome.completed: (200, "Done. Go back to Pal to finish.", True),
    RedirectOutcome.denied: (200, "Nothing was installed. Go back to Pal to try again.", True),
    RedirectOutcome.rejected: (400, "This link has expired or was already used. Go back to Pal and start again.", False),
    RedirectOutcome.failed: (500, "Something went wrong and nothing was installed. Go back to Pal to try again.", True),
}


def return_link(scheme: AppScheme) -> str:
    return _RETURN.format(link=scheme.link("//chat/install-done"))


def _complete(code: str, state: str, error: str) -> tuple[RedirectOutcome, AppScheme]:
    from gateway.chat_install_runtime import build_service
    from hermes_constants import get_hermes_home
    return build_service(get_hermes_home()).complete_redirect(state, code or None, error or None)


@router.get(REDIRECT_PATH)
async def chat_install_callback(code: str = "", state: str = "", error: str = "") -> HTMLResponse:
    try:
        outcome, scheme = await run_in_threadpool(_complete, code, state, error)
    except Exception:  # health: allow BLE001 -- the page must not echo anything, any failure reads as an expired link
        outcome, scheme = RedirectOutcome.rejected, AppScheme.release
    status, message, returns = _PAGES[outcome]
    return HTMLResponse(
        _PAGE.format(message=message, link=return_link(scheme) if returns else ""), status_code=status, headers=_HEADERS)
