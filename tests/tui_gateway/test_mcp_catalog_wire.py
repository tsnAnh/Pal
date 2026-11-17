from tui_gateway.contracts.tools_mcp_plugins import McpCatalogResult


def test_a_catalog_entry_with_its_setup_note_satisfies_the_wire_contract():
    entry = {"name": "linear", "description": "Issues", "connector_slug": None, "signin_on": None, "installed": False,
             "enabled": False, "requires": [], "setup": "Run once", "transport": "stdio", "needs_auth_reason": None}
    assert McpCatalogResult.model_validate({"servers": [entry]}).servers[0].setup == "Run once"
