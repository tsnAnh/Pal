"""``VaultStore._read_all`` must surface every decryptable-but-malformed vault
file as ``VaultError`` so callers that catch ``VaultError`` (the ``hermes vault``
commands, ``vault.*`` RPC handlers) get the designed error path instead of a raw
traceback. Corruption arrives via partial-write survivors, manual edits of the
envelope, or format drift."""

import pytest

from agent.vault_store import VaultError, VaultStore


def _corrupt(store: VaultStore, payload: bytes) -> None:
    store._vault_path.write_bytes(store._fernet().encrypt(payload))


def _store(tmp_path) -> VaultStore:
    store = VaultStore(tmp_path / "vault")
    store.add_item(
        "login",
        "Example login",
        {"identifier_type": "email", "identifier": "u@example.com", "password": "pw"},
        origin="https://example.com",
    )
    return store


@pytest.mark.parametrize(
    "op",
    ["list_items", "get_meta", "remove_item", "resolve_secret", "add_item"],
)
def test_corrupt_vault_raises_vault_error_on_every_reader(tmp_path, op):
    """Every ``_read_all`` consumer must see the same VaultError contract so
    callers that catch VaultError all get the designed error path."""
    store = _store(tmp_path)
    _corrupt(store, b"{not json")
    call = {
        "list_items": lambda: store.list_items(),
        "get_meta": lambda: store.get_meta("vault_x"),
        "remove_item": lambda: store.remove_item("vault_x"),
        "resolve_secret": lambda: store.resolve_secret("vault_x"),
        "add_item": lambda: store.add_item(
            "login",
            "x",
            {"identifier_type": "email", "identifier": "u", "password": "p"},
            origin="https://x.example",
        ),
    }[op]
    with pytest.raises(VaultError):
        call()


API_KEY = "test-key-do-not-use"
PASSWORD = "test-pw-do-not-use"
LOGIN_SECRET = {"identifier_type": "email", "identifier": "u@example.com", "password": PASSWORD}
CARD = {"card_number": PASSWORD, "exp_month": "07", "exp_year": "2030", "cvc": API_KEY}
ADDRESS = {"address_line1": "1 Main St", "city": "Hanoi", "postal_code": "10000", "country": "Vietnam"}


def test_api_key_item_stores_one_secret_and_no_origin_or_identifier(tmp_path):
    store = VaultStore(tmp_path / "vault")
    meta = store.add_item("api_key", "  OpenAI  ", {"api_key": API_KEY}, origin="https://ignored.example")
    assert (meta.kind, meta.label, meta.origin, meta.identifier) == ("api_key", "OpenAI", None, None)
    assert store.resolve_secret(meta.id) == {"api_key": API_KEY}
    assert API_KEY not in str(meta.to_dict())


@pytest.mark.parametrize("label,secret", [
    ("", {"api_key": API_KEY}),
    ("   ", {"api_key": API_KEY}),
    ("OpenAI", {"api_key": "   "}),
    ("OpenAI", {"api_key": None}),
    ("OpenAI", {}),
    ("OpenAI", {"api_key": API_KEY, "password": PASSWORD}),
    ("OpenAI", {"api_key": API_KEY, "extra": "x"}),
])
def test_api_key_add_rejects_blank_label_blank_key_and_extra_fields(tmp_path, label, secret):
    store = VaultStore(tmp_path / "vault")
    with pytest.raises(VaultError) as raised:
        store.add_item("api_key", label, secret)
    assert API_KEY not in str(raised.value) and PASSWORD not in str(raised.value)
    assert store.list_items() == []


def test_update_unknown_id_is_a_vault_error(tmp_path):
    with pytest.raises(VaultError, match="no vault item"):
        VaultStore(tmp_path / "vault").update_item("vault_missing", label="x")


def test_update_login_keeps_blank_fields_and_replaces_provided_ones(tmp_path):
    store = VaultStore(tmp_path / "vault")
    item = store.add_item("login", "Example", dict(LOGIN_SECRET), origin="https://example.com")
    kept = store.update_item(item.id, label=" Renamed ", secret={"password": "", "otp_secret": "  ", "identifier": ""})
    assert (kept.label, kept.identifier, kept.origin, kept.kind) == ("Renamed", "u@example.com", "https://example.com", "login")
    assert store.resolve_secret(item.id) == {"password": PASSWORD}
    changed = store.update_item(item.id, origin="https://other.example:8443", secret={
        "password": API_KEY, "otp_secret": "jbsw y3dp ehpk 3pxp", "identifier": "v@example.com", "identifier_type": "username"})
    assert (changed.origin, changed.identifier, changed.identifier_type, changed.has_otp) == (
        "https://other.example:8443", "v@example.com", "username", True)
    assert store.resolve_secret(item.id) == {"password": API_KEY, "otp_secret": "JBSWY3DPEHPK3PXP"}


@pytest.mark.parametrize("kwargs", [
    {"label": ""},
    {"label": "  "},
    {"origin": ""},
    {"origin": "not-an-origin"},
    {"secret": {"identifier_type": "fax"}},
    {"secret": {"otp_secret": "!!not base32!!"}},
    {"secret": {"api_key": API_KEY}},
    {"secret": {"card_number": PASSWORD}},
    {"secret": "x"},
])
def test_update_login_rejects_invalid_input_and_leaves_the_item_untouched(tmp_path, kwargs):
    store = VaultStore(tmp_path / "vault")
    item = store.add_item("login", "Example", dict(LOGIN_SECRET), origin="https://example.com")
    with pytest.raises(VaultError):
        store.update_item(item.id, **kwargs)
    assert store.get_meta(item.id) == item
    assert store.resolve_secret(item.id) == {"password": PASSWORD}


def test_update_payment_and_address_merge_fields_and_clear_origin_with_blank(tmp_path):
    store = VaultStore(tmp_path / "vault")
    card = store.add_item("payment", "Visa", dict(CARD), origin="https://shop.example")
    store.update_item(card.id, secret={"cvc": PASSWORD, "card_number": "", "billing_postal_code": "70000"})
    assert store.resolve_secret(card.id) == {**CARD, "cvc": PASSWORD, "billing_postal_code": "70000"}
    assert store.update_item(card.id, origin="").origin is None
    home = store.add_item("address", "Home", dict(ADDRESS))
    updated = store.update_item(home.id, secret={"city": "Da Nang", "address_line2": "Apt 4"})
    assert updated.origin is None
    assert store.resolve_secret(home.id) == {**ADDRESS, "city": "Da Nang", "address_line2": "Apt 4"}
    with pytest.raises(VaultError):
        store.update_item(home.id, secret={"password": PASSWORD})


def test_update_api_key_replaces_or_keeps_the_key_and_ignores_origin(tmp_path):
    store = VaultStore(tmp_path / "vault")
    item = store.add_item("api_key", "OpenAI", {"api_key": API_KEY})
    store.update_item(item.id, label="OpenAI prod", secret={"api_key": ""})
    assert store.resolve_secret(item.id) == {"api_key": API_KEY}
    meta = store.update_item(item.id, origin="https://ignored.example", secret={"api_key": f" {PASSWORD} "})
    assert (meta.label, meta.origin, meta.kind) == ("OpenAI prod", None, "api_key")
    assert store.resolve_secret(item.id) == {"api_key": PASSWORD}
    with pytest.raises(VaultError):
        store.update_item(item.id, secret={"password": PASSWORD})


def test_scrub_covers_generic_values_and_api_key_echoes():
    from agent.vault_store import scrub_secret_from_text

    out = scrub_secret_from_text(f"bad {API_KEY} and api_key={PASSWORD}", {"api_key": f" {API_KEY} "})
    assert API_KEY not in out and PASSWORD not in out
