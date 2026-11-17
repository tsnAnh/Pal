import pytest

from hermes_cli.pal_connectors import ConnectionMethod, PalCatalogError, load_pal_connectors


def test_shipped_catalog_loads_with_unique_ids_and_sourced_verified_entries():
    entries = load_pal_connectors()
    ids = [e.id for e in entries]
    assert len(ids) == len(set(ids))
    assert all(e.source.startswith("https://") for e in entries if e.verified)
    assert {e.method for e in entries} <= set(ConnectionMethod)
    assert all(e.mcp_url or e.oauth for e in entries if e.method is ConnectionMethod.MCP_OAUTH and e.id != "n8n-official")


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
    assert {"google-workspace", "github", "slack"} <= set(guided)
    for entry in guided.values():
        assert len({s.id for s in entry.setup.steps}) == len(entry.setup.steps)
        assert all(s.fields for s in entry.setup.steps if s.kind == "paste")
    assert guided["slack"].method is ConnectionMethod.OAUTH_CLIENT and guided["slack"].mcp_url
    for slug in ("figma", "dropbox"):
        assert guided[slug].method is ConnectionMethod.OAUTH_CLIENT and guided[slug].mcp_url and guided[slug].oauth
        assert all(s.check is None for s in guided[slug].setup.steps)


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
