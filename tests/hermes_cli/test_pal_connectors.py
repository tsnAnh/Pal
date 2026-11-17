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
    "slack", "clickhouse", "mintlify", "upwork",
})


def test_shipped_catalog_is_exactly_the_owner_picks():
    ids = {e.id for e in load_pal_connectors()}
    assert ids == OWNER_PICKS
    assert len(ids) == 50 and "discord" not in ids


def test_shipped_catalog_loads_with_unique_ids_and_sourced_verified_entries():
    entries = load_pal_connectors()
    ids = [e.id for e in entries]
    assert len(ids) == len(set(ids))
    assert all(e.source.startswith("https://") for e in entries if e.verified)
    assert {e.method for e in entries} <= set(ConnectionMethod)
    assert all(e.mcp_url or e.oauth for e in entries if e.method is ConnectionMethod.MCP_OAUTH)


def test_a_bot_app_entry_needs_no_endpoint_and_slack_is_one():
    entries = {e.id: e for e in load_pal_connectors()}

    assert entries["slack"].method is ConnectionMethod.BOT_APP
    assert entries["slack"].mcp_url is None and entries["slack"].oauth is None
    assert entries["slack"].category == "Communication" and entries["slack"].icon == "plugin_glyph"


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


def test_setup_guides_parse_with_ordered_steps_and_valid_shapes():
    guided = {e.id: e for e in load_pal_connectors() if e.setup}
    assert {"google-workspace", "github"} <= set(guided)
    for entry in guided.values():
        assert len({s.id for s in entry.setup.steps}) == len(entry.setup.steps)
        assert all(s.fields for s in entry.setup.steps if s.kind == "paste")
    for slug in ("figma", "dropbox"):
        assert guided[slug].method is ConnectionMethod.OAUTH_CLIENT and guided[slug].mcp_url and guided[slug].oauth
        assert all(s.check is None for s in guided[slug].setup.steps)
    canva = guided["canva"]
    assert canva.method is ConnectionMethod.OAUTH_CLIENT and canva.mcp_url == "https://api.canva.com/connect/v1/mcp"
    assert [s.check for s in canva.setup.steps] == [None, "canva_client"]


@pytest.mark.parametrize("step", [
    "{id: a, kind: wizard, title: T, body: B}",
    "{id: a, kind: paste, title: T, body: B}",
    "{id: a, kind: open_page, title: T, body: B, check: github_token}",
    "{id: a, kind: open_page, title: T, body: B, links: [{label: x, url: nope}]}",
], ids=["unknown-kind", "paste-without-fields", "check-on-open-page", "relative-link"])
def test_invalid_setup_step_is_refused(tmp_path, step):
    path = tmp_path / "c.yaml"
    path.write_text("version: 1\nconnectors:\n- {id: a, name: A, icon: i, category: c, method: none, verified: false, "
                    f"source: https://x.dev, setup: {{steps: [{step}]}}}}\n")
    with pytest.raises(PalCatalogError):
        load_pal_connectors(path)


def test_step_fallback_parses_with_links(tmp_path):
    path = tmp_path / "c.yaml"
    path.write_text("version: 1\nconnectors:\n- {id: a, name: A, icon: i, category: c, method: none, verified: false, "
                    "source: https://x.dev, setup: {steps: [{id: a, kind: open_page, title: T, body: B, "
                    "fallback: {label: L, body: FB, links: [{label: x, url: 'https://y.dev'}]}}]}}\n")
    step = load_pal_connectors(path)[0].setup.steps[0]
    assert (step.fallback.label, step.fallback.body, step.fallback.links[0].url) == ("L", "FB", "https://y.dev")


@pytest.mark.parametrize("fallback", ["{label: L}", "{label: L, body: B, extra: 1}", "nope"])
def test_invalid_step_fallback_is_refused(tmp_path, fallback):
    path = tmp_path / "c.yaml"
    path.write_text("version: 1\nconnectors:\n- {id: a, name: A, icon: i, category: c, method: none, verified: false, "
                    f"source: https://x.dev, setup: {{steps: [{{id: a, kind: open_page, title: T, body: B, fallback: {fallback}}}]}}}}\n")
    with pytest.raises(PalCatalogError):
        load_pal_connectors(path)
