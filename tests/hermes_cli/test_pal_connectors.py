import pytest

from hermes_cli.pal_connectors import ConnectionMethod, PalCatalogError, load_pal_connectors

OWNER_PICKS = frozenset({
    "github", "gitlab", "vercel", "netlify", "cloudflare", "railway", "supabase", "neon", "prisma-postgres",
    "motherduck", "circleci", "buildkite", "postman", "semgrep", "context7", "deepwiki", "hugging_face",
    "aws-knowledge", "microsoft-learn", "twilio-docs", "unreal-engine", "wolfram",
    "sentry", "grafana", "datadog",
    "linear", "atlassian", "clickup", "monday", "todoist", "notion", "airtable", "craft", "miro",
    "google-workspace", "dropbox", "figma", "canva", "gamma", "cloudinary", "comfy-cloud", "webflow", "wordpress-com",
    "stripe", "intercom", "calendly",
    "slack", "clickhouse", "mintlify",
})


def test_shipped_catalog_is_exactly_the_owner_picks():
    ids = {e.id for e in load_pal_connectors()}
    assert ids == OWNER_PICKS
    assert len(ids) == 49 and "discord" not in ids


def test_shipped_catalog_loads_with_unique_ids_and_sourced_verified_entries():
    entries = load_pal_connectors()
    ids = [e.id for e in entries]
    assert len(ids) == len(set(ids))
    assert all(e.source.startswith("https://") for e in entries if e.verified)
    assert {e.method for e in entries} <= set(ConnectionMethod)
    assert all(e.mcp_url or e.oauth for e in entries if e.method is ConnectionMethod.MCP_OAUTH)


def test_catalog_never_routes_through_portal_or_composio():
    for e in load_pal_connectors():
        for url in filter(None, (e.mcp_url, e.oauth and e.oauth.token_url, e.oauth and e.oauth.authorization_url)):
            assert "nousresearch" not in url and "composio" not in url, e.id


@pytest.mark.parametrize(
    "body",
    [
        "version: 1\nconnectors:\n- {id: a, name: A, icon: i, category: c, method: mcp_oauth, verified: true, source: https://x.dev}\n"
        "- {id: a, name: B, icon: i, category: c, method: none, verified: false, source: https://y.dev}\n",
        "version: 1\nconnectors:\n- {id: a, name: A, icon: i, category: c, method: portal, verified: true, source: https://x.dev}\n",
        "version: 1\nconnectors:\n- {id: a, name: A, icon: i, category: c, method: none, verified: true}\n",
        "version: 1\nconnectors:\n- {id: a, name: A, icon: i, category: c, method: oauth_client, verified: false, source: https://x.dev}\n",
    ],
    ids=["duplicate-id", "unknown-method", "verified-without-source", "oauth-client-without-endpoints"],
)
def test_invalid_catalog_is_refused(tmp_path, body):
    path = tmp_path / "c.yaml"
    path.write_text(body)
    with pytest.raises(PalCatalogError):
        load_pal_connectors(path)
