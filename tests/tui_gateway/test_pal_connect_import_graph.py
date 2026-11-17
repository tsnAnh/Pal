import json
import subprocess
import sys

PAL_CONNECT_MODULES = (
    "tui_gateway.methods_connectors_account",
    "tui_gateway.methods_connectors",
    "tui_gateway.oauth_client_rpc",
    "tui_gateway.mcp_oauth_sessions",
    "tools.connectors.catalog",
    "tools.connectors.legacy",
    "tools.connectors.mcp",
    "tools.connectors.mcp_oauth",
    "tools.connectors.live",
)

PROBE = """
import json, sys
for name in sys.argv[1:]:
    __import__(name)
print(json.dumps(sorted(m for m in sys.modules if m.startswith(("tools.connectors.portal", "tools.connectors.gateway")))))
"""


def test_pal_direct_connect_handlers_load_without_portal_or_vendor_client():
    out = subprocess.run(
        [sys.executable, "-c", PROBE, *PAL_CONNECT_MODULES], capture_output=True, text=True, check=True,
    ).stdout
    assert json.loads(out.strip().splitlines()[-1]) == []
