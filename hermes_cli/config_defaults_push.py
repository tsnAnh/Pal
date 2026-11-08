from hermes_cli.config_defaults_env import _setting

PUSH_DEFAULTS = {"apns": {"key_id": "", "team_id": "", "topic": ""}}

PUSH_ENV_VARS = {
    "APNS_AUTH_KEY": _setting(
        "Contents of the Apple Push Notification service .p8 signing key (PEM; \\n escapes accepted). "
        "Key ID, team ID and topic go in push.apns of config.yaml.",
        "APNs signing key contents (leave empty when using APNS_AUTH_KEY_PATH)", None,
        password=True, advanced=True),
    "APNS_AUTH_KEY_PATH": _setting(
        "Path to the Apple Push Notification service .p8 signing key file",
        "APNs signing key file path (leave empty when using APNS_AUTH_KEY)", None,
        password=True, advanced=True),
}
