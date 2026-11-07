CHRONOS_DEFAULTS = {
    # NAS/portal base URL that arms/cancels one-shots and mints the inbound fire JWT (used
    # as the expected issuer).
    "portal_url": "https://portal.nousresearch.com",
    # This agent's publicly reachable base URL; NAS POSTs {callback_url}/api/cron/fire. ""
    # -> Chronos unavailable, resolver falls back to the built-in ticker.
    "callback_url": "",
    "expected_audience": "",  # Expected JWT audience (e.g. "agent:{instance_id}").
    # NAS JWKS URL for verifying the fire JWT signature. "" -> the fire endpoint refuses all
    # tokens (never an unsigned decode).
    "nas_jwks_url": "",
}
