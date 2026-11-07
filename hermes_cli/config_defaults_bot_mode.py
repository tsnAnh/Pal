# Bot Mode cross-connection relay (tools/bot_relay.py): envelopes queued by message_agent for
# agents on other connections wait in an on-disk outbox until the Desktop drains them.
BOT_MODE_DEFAULTS = {
    # Drain-time TTL (seconds): older envelopes are NOT delivered on drain; the sender gets an
    # error reply (reason 'queued_expired') so a DM can't land hours late as a zombie. 0 = no
    # drain-time expiry (the 6h stale-artifact sweep still applies).
    "envelope_ttl_seconds": 900,
    # How long a second delivery into a busy target profile queues behind the current turn
    # before failing with a structured 'target_busy' error. Deliveries are serialized per
    # profile with a cross-process file lock.
    "turn_wait_seconds": 120,
    "notifications": False,
}
