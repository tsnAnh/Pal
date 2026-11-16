"""Config-credential key list and the content-level pass that masks it, shared by every config reader
(``hermes config get/show``, ``read_file``/``search_files``, terminal output). Split from agent/redact.py."""

import re

CONFIG_SECRET_PLACEHOLDER = "«redacted-secret»"
CONFIG_SECRET_KEYS = frozenset({
    "api_key", "apikey", "key", "token", "access_token", "refresh_token", "id_token",
    "secret", "client_secret", "password", "password_hash", "passwd", "passphrase", "credential",
    "credentials", "authorization", "private_key", "bearer", "jwt"})
CONFIG_SECRET_KEY_SUFFIXES = ("_api_key", "_token", "_secret", "_password", "_password_hash", "_key", "_access_key")
CONFIG_AMBIGUOUS_KEYS = frozenset({
    "key", "token", "api_key", "apikey", "bearer", "jwt", "authorization", "password", "passwd"})
CONFIG_AMBIGUOUS_SUFFIXES = ("_key", "_token", "_api_key", "_access_key", "_password")


def is_config_secret_leaf(leaf: str, *, bare_words: bool = True) -> bool:
    """Whether a config key's last segment names a credential, by the one list every config reader shares.
    ``bare_words=False`` drops the words that also name ordinary source fields (``key``, ``token``,
    ``password: example`` fixtures, ``cache_key``) for readers that cannot tell a Hermes config from other YAML."""
    leaf = leaf.lower().replace("-", "_")
    suffixes = CONFIG_SECRET_KEY_SUFFIXES if bare_words else tuple(
        s for s in CONFIG_SECRET_KEY_SUFFIXES if s not in CONFIG_AMBIGUOUS_SUFFIXES)
    return (leaf in CONFIG_SECRET_KEYS and (bare_words or leaf not in CONFIG_AMBIGUOUS_KEYS)) or leaf.endswith(suffixes)


_CONFIG_LINE_RE = re.compile(
    r"^([ \t]*+(?:[^\s:=]++[:\-][0-9]++[:\-][ \t]*+|[0-9]++(?:[|:\-]|\t)[ \t]*+)?(?:-[ \t]++)?)"
    r"([A-Za-z0-9_\-]++)(:[ \t]*+)(\"(?:\\[^\r\n]|[^\"\\\r\n])*\"|'(?:''|[^'\r\n])*'|[^\r\n]+?(?=[ \t]*(?:#.*)?$))",
    re.MULTILINE)
_CONFIG_CREDENTIAL_WORD_RE = re.compile(r"password|passwd|passphrase|secret|credential|api[_\-]?key|private[_\-]?key", re.IGNORECASE)


def redact_config_credential_lines(text: str) -> str:
    """Mask ``key: value`` lines whose key is on the shared config credential list, whatever file the text
    came from: ``cat config.yaml`` in a Hermes home, ``grep -rn secret ~/.hermes`` and a relative path name
    no secret file, so the classifier-gated passes never run on them. Words that ordinary YAML and source
    examples also use (``key``, ``token``, ``api_key``, ``password``) stay out here."""
    from agent.redact import _DSN_PW_PLACEHOLDER_RE, _ENV_LOOKUP_VALUE_RE
    if ":" not in text or not _CONFIG_CREDENTIAL_WORD_RE.search(text):
        return text

    def _mask(m):
        prefix, key, sep, value = m.groups()
        inner = value[1:-1] if value[0] in "\"'" and len(value) >= 2 and value[-1] == value[0] else value
        if (not is_config_secret_leaf(key, bare_words=False) or not inner or inner.startswith("«")
                or _DSN_PW_PLACEHOLDER_RE.fullmatch(inner) or _ENV_LOOKUP_VALUE_RE.match(inner)):
            return m.group(0)
        quote = value[0] if inner != value else ""
        return f"{prefix}{key}{sep}{quote}{CONFIG_SECRET_PLACEHOLDER}{quote}"
    return _CONFIG_LINE_RE.sub(_mask, text)
