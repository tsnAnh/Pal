# Pal app (apps/ios) - Development Guide

iPhone and Mac app. Not the Electron app (`apps/desktop`).

## Connectors that need auth must raise the sign-in dialog

Any new connector, MCP preset or service tool that can fail on a missing, expired or revoked credential must
declare its auth type and surface the failure through `tools/auth_required.py`, so the gateway raises
`auth.required` and the app shows `ServiceSignInView`.

- Declare: catalog manifests carry `auth.type` (`oauth` | `api_key` | `none`); hosted connectors use the
  `CONNECTION_REQUIRED` / `CONNECTION_EXPIRED` codes; anything else returns `auth_required_result(service, reason)`
  (or `http_auth_failure(service, status, headers)` for a 401/403).
- Flow: register a `SigninFlow` for the service prefix in `gateway/auth_flows.py` (`register(prefix, factory)`);
  flows are `device_code`, `oauth`, `api_key` (SecureField -> `mcp.servers.set_api_key`), `header`, `manual`.
- A new Connected apps source kind in `ConnectCatalog.swift` must be added to `auth_flows.CONNECT_APP_SOURCES`.
- Enforced by `tests/gateway/test_auth_catalog.py`: it walks every `optional-mcps` manifest, raises the event
  through the real detection path and fails on a missing auth type, a Swift enum drifting from
  `tui_gateway/contracts/canonical_auth.py`, or an undeclared source kind.
- Secrets: the app never receives a token. Keys go from the SecureField straight to the gateway's secret path;
  never echo, log or store them. URLs open in the system browser only (never `WKWebView`, `SFSafariViewController`).
