from __future__ import annotations

import pytest

from hermes_cli.pal_connectors import ConnectionMethod, PalCatalogError, load_pal_connectors
from tools.mcp_action_gate import ACTION, READ, REFUSED, ActionPolicy

NEW_IDS = ("posthog", "resend", "higgsfield", "shopify", "paypal", "slack_mcp", "discord_mcp")
ENTRIES = {e.id: e for e in load_pal_connectors()}


@pytest.mark.parametrize("cid", NEW_IDS)
def test_every_new_entry_has_a_plain_description_and_an_https_source(cid):
    entry = ENTRIES[cid]

    assert entry.description.endswith(".") and "\n" not in entry.description and len(entry.description) <= 160
    assert entry.source.startswith("https://")
    assert entry.icon and entry.category


def test_the_vendor_addresses_are_the_ones_the_owner_named():
    assert {cid: ENTRIES[cid].mcp_url for cid in ("posthog", "resend", "higgsfield", "paypal", "slack_mcp", "discord_mcp")} == {
        "posthog": "https://mcp.posthog.com/mcp", "resend": "https://mcp.resend.com/mcp",
        "higgsfield": "https://mcp.higgsfield.ai/mcp", "paypal": "https://mcp.paypal.com/mcp",
        "slack_mcp": "https://mcp.slack.com/mcp", "discord_mcp": "https://mcp.discord.com/mcp"}


def test_shopify_has_no_fixed_address_because_the_owner_enters_a_store():
    shopify = ENTRIES["shopify"]

    assert shopify.mcp_url is None and shopify.method is ConnectionMethod.NONE and not shopify.cimd


def test_slack_and_discord_tools_sign_in_with_the_owners_own_oauth_client():
    for cid, token_host in (("slack_mcp", "slack.com"), ("discord_mcp", "discord.com")):
        entry = ENTRIES[cid]
        assert entry.method is ConnectionMethod.OAUTH_CLIENT and entry.mcp_url
        assert token_host in entry.oauth.token_url and entry.scopes
        paste = next(s for s in entry.setup.steps if s.kind == "paste")
        assert [(f.id, f.secret) for f in paste.fields] == [("client_id", False), ("client_secret", True)]
        assert [s.kind for s in entry.setup.steps] == ["public_url", "open_page", "paste"]
    assert ENTRIES["slack"].method is ConnectionMethod.BOT_APP and ENTRIES["discord"].method is ConnectionMethod.BOT_TOKEN_STDIO


def _policy() -> ActionPolicy:
    return ActionPolicy.from_config(ENTRIES["paypal"].action_policy.config())


@pytest.mark.parametrize("tool", [
    "list_invoices", "get_invoice", "search_invoicing", "generate_invoice_number", "get_recurring_series",
    "list_products", "show_product_details", "list_subscription_plans", "show_subscription_plan_details",
    "show_subscription_details", "get_shipment_tracking", "get_order", "list_disputes", "get_dispute",
    "list_transactions", "get_refund", "get_merchant_insights"])
def test_paypal_reads_run_on_their_own(tool):
    assert _policy().classify(tool) == READ


@pytest.mark.parametrize("tool", [
    "create_order", "pay_order", "create_refund", "record_payment_for_invoice", "record_refund_for_invoice",
    "send_invoice", "send_invoice_reminder", "create_subscription", "update_subscription", "accept_dispute_claim",
    "activate_recurring_series", "capture_order", "authorize_payment", "create_payout", "batch_payouts",
    "charge_card", "transfer_funds", "withdraw_balance", "pay_invoice", "CreateOrder", "payOrder",
    "create_subscription_plan"])
def test_paypal_money_movers_are_refused_whatever_their_spelling(tool):
    assert _policy().classify(tool) == REFUSED


@pytest.mark.parametrize("tool", [
    "create_invoice", "update_invoice", "delete_invoice", "cancel_sent_invoice", "create_product", "update_product",
    "update_plan", "cancel_subscription", "create_shipment_tracking",
    "update_shipment_tracking", "create_recurring_series", "cancel_recurring_series", "setup_invoice_auto_reminders",
    "generate_invoice_qr_code", "some_tool_paypal_adds_later", "list_invoices_v2", ""])
def test_paypal_other_changes_and_unknown_tools_ask_and_never_read(tool):
    assert _policy().classify(tool) == ACTION


def test_paypal_refusal_is_in_product_language():
    message = ENTRIES["paypal"].action_policy.refused_message

    assert "moves money" in message and "PayPal" in message
    assert not any(word in message.lower() for word in ("tool", "policy", "mcp", "refused"))


def _write(tmp_path, body):
    path = tmp_path / "catalog.yaml"
    path.write_text("version: 1\nconnectors:\n- {id: a, name: A, description: d, icon: i, category: c, verified: false, "
                    f"source: https://x.dev, {body}}}\n")
    return path


@pytest.mark.parametrize("body", [
    "method: none, mcp_url: 'https://x.dev/mcp', cimd: true",
    "method: mcp_oauth, cimd: true",
    "method: mcp_oauth, mcp_url: 'https://x.dev/mcp', cimd: yes-please",
    "method: mcp_oauth, mcp_url: 'https://x.dev/mcp', action_policy: {read_tools: [a], refused_message: no}",
    "method: mcp_oauth, mcp_url: 'https://x.dev/mcp', action_policy: {read_tools: [a], refused_tools: [b]}",
    "method: mcp_oauth, mcp_url: 'https://x.dev/mcp', action_policy: {refused_tools: [b], refused_message: no, extra: 1}",
    "method: mcp_oauth, mcp_url: 'https://x.dev/mcp', action_policy: {refused_tools: [3], refused_message: no}",
    "method: none, action_policy: {refused_tools: [b], refused_message: no}"])
def test_the_catalog_refuses_flags_that_cannot_work(tmp_path, body):
    with pytest.raises(PalCatalogError):
        load_pal_connectors(_write(tmp_path, body))


def test_a_valid_flag_and_policy_load(tmp_path):
    (entry,) = load_pal_connectors(_write(
        tmp_path, "method: mcp_oauth, mcp_url: 'https://x.dev/mcp', cimd: true, "
                  "action_policy: {read_tools: [get_x], refused_tools: [pay_x], refused_message: 'Never.'}"))

    assert entry.cimd and entry.action_policy.config() == {
        "read_tools": ["get_x"], "refused_tools": ["pay_x"], "refused_message": "Never."}

