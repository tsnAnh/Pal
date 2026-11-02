from __future__ import annotations

from tests.e2e.core.bots._world import DEAD_URL, World
from tests.fakes.fake_llm_provider import FakeLLMServer

SKILLS: dict[str, str | list[str] | None] = {
    "gated-mcp": "mcp:srv",
    "gated-oauth": "mcp:oauthsrv",
    "gated-multi": ["mcp:srv", "mcp:oauthsrv"],
    "ungated": None,
}
SRV = {"url": DEAD_URL}
OAUTH = {"url": DEAD_URL, "auth": "oauth"}

EXPECTED_VISIBLE = {
    "a": {"gated-mcp", "gated-oauth", "gated-multi", "ungated"},
    "b": {"ungated"},
    "c": {"gated-mcp", "ungated"},
}
MISSING_HINT = {
    ("b", "gated-mcp"): "srv", ("b", "gated-oauth"): "oauthsrv", ("b", "gated-multi"): "srv",
    ("c", "gated-oauth"): "oauthsrv", ("c", "gated-multi"): "oauthsrv",
}


def build(w: World, mode: str, bots: tuple[str, ...] = ("a", "b", "c")) -> None:
    if mode == "legacy":
        defs = {
            "a": ({"srv": dict(SRV), "oauthsrv": dict(OAUTH)}, ["oauthsrv"]),
            "b": ({"srv": {**SRV, "enabled": False}, "oauthsrv": dict(OAUTH)}, []),
            "c": ({"srv": dict(SRV), "oauthsrv": dict(OAUTH)}, []),
        }
        for bot in bots:
            servers, tokens = defs[bot]
            w.add_bot(bot, skills={n: {"connector": c} for n, c in SKILLS.items()}, mcp_servers=servers, tokens=tokens)
        return
    w.save_catalog_mcp({"srv": dict(SRV), "oauthsrv": dict(OAUTH)})
    for name, connector in SKILLS.items():
        w.catalog_skill(name, connector=connector, bundled=True)
    defs = {
        "a": ({"srv": {"enabled": True}, "oauthsrv": {"enabled": True}}, ["oauthsrv"]),
        "b": ({"oauthsrv": {"enabled": True}}, []),
        "c": ({"srv": {"enabled": True}, "oauthsrv": {"enabled": True}}, []),
    }
    for bot in bots:
        servers, tokens = defs[bot]
        w.add_bot(bot, mcp_servers=servers, tokens=tokens)


def point_at(w: World, srv: FakeLLMServer) -> None:
    for bot in w.bots():
        w.update_config(bot, {"model": {"base_url": srv.base_url}})
