from __future__ import annotations

import json
import re
import threading
from urllib.parse import parse_qs

import httpx

from tests.tui_gateway.contracts.chat_provider_fakes import FAKE_TOKEN

REFRESH = f"xoxe-1-{FAKE_TOKEN}"
BOT_TOKEN = f"xoxb-{FAKE_TOKEN}"
CLIENT_SECRET = f"secret-{FAKE_TOKEN}"
AUTH_FREE = {"oauth.v2.access", "tooling.tokens.rotate"}


class FakeSlack:
    def __init__(self, *, icon_ok: bool = True, app_token_ok: bool = True, redirect_ok: bool = True, now: float = 0.0):
        self.icon_ok, self.app_token_ok, self.redirect_ok, self.now = icon_ok, app_token_ok, redirect_ok, now
        self.apps: dict[str, dict] = {}
        self.calls: list[str] = []
        self.created = self.rotations = 0
        self.refresh = {REFRESH}
        self.access: set[str] = set()
        self.fail: dict[str, str] = {}
        self.rate_limit: dict[str, int] = {}
        self.rotate_gate: threading.Event | None = None
        self.joined: set[str] = set()
        self.channels = [{"id": "C1", "name": "general", "is_private": False, "is_member": False},
                         {"id": "G1", "name": "secret-plans", "is_private": True, "is_member": True}]
        self.transport = httpx.MockTransport(self.handle)

    def handle(self, request: httpx.Request) -> httpx.Response:
        method = request.url.path.rsplit("/", 1)[-1]
        self.calls.append(method)
        if self.rate_limit.get(method):
            self.rate_limit[method] -= 1
            return httpx.Response(429, headers={"Retry-After": "3"})
        if method in self.fail:
            error = self.fail[method]
            if error == "network":
                raise httpx.ConnectError("boom", request=request)
            return httpx.Response(200, json={"ok": False, "error": error})
        token = request.headers.get("Authorization", "").removeprefix("Bearer ")
        if method not in AUTH_FREE and token not in self.access | {BOT_TOKEN}:
            return httpx.Response(200, json={"ok": False, "error": "invalid_auth"})
        body = getattr(self, "m_" + method.replace(".", "_"))(self._form(request))
        return httpx.Response(200, json=body)

    @staticmethod
    def _form(request: httpx.Request) -> dict[str, str]:
        content = request.content.decode("latin-1")
        if "multipart" in request.headers.get("content-type", ""):
            return dict(re.findall(r'name="(\w+)"\r\n\r\n([^\r]*)\r\n', content))
        return {k: v[0] for k, v in parse_qs(content).items()}

    def m_tooling_tokens_rotate(self, form):
        if self.rotate_gate:
            self.rotate_gate.wait(5)
        if form.get("refresh_token") not in self.refresh:
            return {"ok": False, "error": "invalid_refresh_token"}
        self.rotations += 1
        self.refresh = {f"xoxe-1-{FAKE_TOKEN}-r{self.rotations}"}
        access = f"xoxe.xoxp-{FAKE_TOKEN}-{self.rotations}"
        self.access = {access}
        return {"ok": True, "token": access, "refresh_token": next(iter(self.refresh)), "exp": self.now + 43200}

    def m_apps_manifest_validate(self, form):
        if self.redirect_ok:
            return {"ok": True}
        return {"ok": False, "error": "invalid_manifest",
                "errors": [{"message": "bad", "pointer": "/oauth_config/redirect_urls/0"}]}

    def m_apps_manifest_create(self, form):
        manifest = json.loads(form["manifest"])
        if not self.redirect_ok and manifest["oauth_config"].get("redirect_urls"):
            return {"ok": False, "error": "invalid_manifest"}
        self.created += 1
        app_id = f"A{self.created}"
        self.apps[app_id] = manifest
        return {"ok": True, "app_id": app_id, "oauth_authorize_url": f"https://slack.invalid/oauth?app={app_id}",
                "credentials": {"client_id": f"cid-{app_id}", "client_secret": CLIENT_SECRET}}

    def m_apps_manifest_update(self, form):
        if form["app_id"] not in self.apps:
            return {"ok": False, "error": "app_not_found"}
        self.apps[form["app_id"]] = json.loads(form["manifest"])
        return {"ok": True}

    def m_apps_manifest_delete(self, form):
        if self.apps.pop(form["app_id"], None) is None:
            return {"ok": False, "error": "app_not_found"}
        return {"ok": True}

    def m_apps_icon_set(self, form):
        return {"ok": True} if self.icon_ok else {"ok": False, "error": "unknown_method"}

    def m_apps_token_create(self, form):
        return {"ok": True, "token": f"xapp-{FAKE_TOKEN}"} if self.app_token_ok else {"ok": False, "error": "unknown_method"}

    def m_oauth_v2_access(self, form):
        if form.get("client_secret") != CLIENT_SECRET:
            return {"ok": False, "error": "invalid_client"}
        return {"ok": True, "access_token": BOT_TOKEN, "bot_user_id": "UBOT", "team": {"id": "T1", "name": "Acme"},
                "authed_user": {"id": "UOWNER"}}

    def m_conversations_list(self, form):
        return {"ok": True, "channels": self.channels, "response_metadata": {"next_cursor": ""}}

    def m_conversations_join(self, form):
        if form["channel"].startswith("G"):
            return {"ok": False, "error": "method_not_supported_for_channel_type"}
        already = form["channel"] in self.joined
        self.joined.add(form["channel"])
        return {"ok": True, **({"warning": "already_in_channel"} if already else {})}

    def m_auth_test(self, form):
        return {"ok": True, "team_id": "T1", "team": "Acme", "user_id": "UBOT", "bot_id": "B1"}

    def m_auth_revoke(self, form):
        return {"ok": True}
