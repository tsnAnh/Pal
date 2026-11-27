"""Tool approval: what refuses a tool call, and the owner-decision wait for what must be asked.

A command or script the agent runs is never put to a prompt. ``check_all_command_guards``,
``check_dangerous_command`` and ``check_execute_code_guard`` refuse (hardline commands, runtime
self-delete, ``sudo -S`` password piping, the operator's ``approvals.deny`` rules, an agent-run bot or
profile create outside a turn the owner typed in the app) and, in a context nobody can answer (``-q``,
cron, an unattended platform), apply ``approvals.single_query_mode`` / ``cron_mode`` /
``unattended_mode``. Everything else runs.

What still asks the owner is content that sends out or spends money: outbound sends
(``request_draft_approval``) and ``approval_prompt.request_elicitation_consent``. Both ride the gateway
queue below, one operation at a time (once or deny); an outbound send to one shown destination may also be answered
always, which saves a rule (``tools.send_rules``). Leaves: ``approval_detection`` (hardline and
dangerous-pattern detection), ``approval_context`` (contextvars, config readers), ``approval_floors``
(refusal results, deny rules), ``approval_prompt`` (CLI prompt, elicitation consent),
``approval_gateway_wait`` (blocking gateway round-trip), ``approval_human_wait``. Leaves read facade-owned
state (``_lock``, queues) back through ``tools.approval`` at call time.
"""

from collections.abc import Mapping
from dataclasses import dataclass
import importlib
import logging
import threading
from typing import TYPE_CHECKING, Any, Optional

from utils import env_var_enabled
from agent.i18n import t
from tools import approval_context
from tools.approval_context import (
    _get_session_platform, _is_cron_approval_context,
    _is_gateway_approval_context, _is_interactive_cli, _is_single_query_approval_context,
    _is_unattended_platform_approval_context, _resolve_cli_approval_callback, _should_fall_through_to_cli_approval,
    get_current_session_key,
)
from tools.approval_detection import (
    _SCAN_INCOMPLETE_DESCRIPTION, _check_sudo_stdin_guard, detect_content_rule_keys,
    detect_dangerous_command, detect_hardline_command, hardline_scan_incomplete,
)
from tools.approval_detection_human import creates_bot_or_profile
from tools.approval_floors import (
    _hardline_block_result, _match_user_deny_rule, _sudo_stdin_block_result, _user_deny_block_result,
)
from tools.approval_gateway_wait import _await_gateway_decision
from tools.approval_prompt import prompt_dangerous_approval
from tools.mcp_action_gate import approver_present
from tools.skill_provenance import is_background_review

if TYPE_CHECKING:
    from tools.send_rules import SendRuleCandidate

logger = logging.getLogger(__name__)


# --- Gateway state (thread-safe) ------------------------------------------------------------------------------------

_lock = threading.RLock()  # re-entrant: a card settle checks and resolves under one hold
# --- Gateway approval queue (the blocking wait loop lives in approval_gateway_wait) ---------------------------------

_gateway_queues: dict[str, list] = {}        # session_key → [_ApprovalEntry, …]
_gateway_notify_cbs: dict[str, object] = {}  # session_key → callable(approval_data)


def register_gateway_notify(session_key: str, cb) -> None:
    """Register ``cb(approval_data: dict) -> None`` for sending approval requests. The callback
    bridges sync→async: it runs in the agent thread and must schedule the send on the loop."""
    with _lock:
        _gateway_notify_cbs[session_key] = cb


def unregister_gateway_notify(session_key: str) -> None:
    """Withdraw foreground waits when the turn ends. Dispatch-owned background
    waits survive until their worker ends or the session is cleared."""
    with _lock:
        _gateway_notify_cbs.pop(session_key, None)
        queue = _gateway_queues.get(session_key, [])
        for entry in list(queue):
            # A background child's wait stays answerable when its lease can still deliver prompts.
            if entry.owner is None or entry.owner.callback is None:
                queue.remove(entry)
                entry.event.set()
        if not queue:
            _gateway_queues.pop(session_key, None)


def resolve_gateway_approval(session_key: str, choice: str,
                             resolve_all: bool = False,
                             reason: Optional[str] = None,
                             request_id: Optional[str] = None,
                             edited_text: Optional[str] = None) -> int:
    """Unblock waiting agent thread(s) from the owner's answer.

    *resolve_all* resolves every pending approval; otherwise the oldest
    (FIFO) or the one matching *request_id*. *reason* is the free text sent with a deny,
    relayed to the agent in the BLOCKED message. *edited_text* is the owner's rewrite of one outbound
    draft, honoured only on ``once``, only when a single *request_id* is targeted and only by gates that
    accept edits. Returns the number resolved.
    """
    # Canonicalize where the answer is stored, not only in ``grant``: coalesced followers
    # (``choice == "once"`` covers only the leader) and the protected-write and elicitation
    # gates read ``entry.result`` directly, so an alias of "once" must already be "once" here.
    asks_to_remember = isinstance(choice, str) and choice.strip().lower() == "always"
    choice = canonical_approval_choice(choice)
    with _lock:
        queue = _gateway_queues.get(session_key)
        if not queue:
            return 0
        if request_id:
            entry = _entry_for_request(session_key, request_id)
            if entry is None:
                return 0
            queue.remove(entry)
            targets = [entry]
        elif resolve_all:
            targets = list(queue)
            queue.clear()
        else:
            targets = [queue.pop(0)]
        if not queue:
            _gateway_queues.pop(session_key, None)
        # Popping the entry and committing its outcome are ONE critical section: the waiter's
        # ``_drop_entry`` reads ``entry.result`` under this same lock after its deadline check, so a
        # choice acked to the client here can never be popped-and-lost as a timeout (#112548).
        for entry in targets:
            entry.result = choice
            if reason:
                entry.reason = reason
            if edited_text is not None and choice == "once" and request_id and len(targets) == 1:
                entry.edited_text = edited_text
            entry.remember = bool(asks_to_remember and request_id and offered_choices(entry.data) == SEND_RULE_CHOICES)
            entry.event.set()
    return len(targets)


def _entry_for_request(session_key: str, request_id: Optional[str]):
    """The pending entry with this ``request_id`` (a fresh uuid per entry, so at most one), never
    another. Caller holds ``_lock``."""
    if not request_id:
        return None
    return next((e for e in _gateway_queues.get(session_key) or [] if e.data.get("request_id") == request_id), None)


def choices_for_request(session_key: str, request_id: Optional[str]) -> list[str]:
    with _lock:
        entry = _entry_for_request(session_key, request_id)
        return offered_choices(entry.data if entry is not None else {})


def withdraw_gateway_approval(session_key: str, request_id: str, cause: str) -> bool:
    """Withdraw one pending approval nobody can answer (the only attached client cannot render it).
    The waiter wakes at once with ``cancelled=cause`` — a withdrawal, never a user deny — instead of
    idling for the whole approvals.timeout (#112548). False when it is no longer pending."""
    with _lock:
        entry = _entry_for_request(session_key, request_id)
        if entry is None:
            return False
        queue = _gateway_queues[session_key]
        queue.remove(entry)
        if not queue:
            _gateway_queues.pop(session_key, None)
        entry.cancelled = cause
        entry.event.set()
    return True


def list_gateway_approvals(session_key: str) -> list[dict]:
    """Return replay-safe snapshots of unresolved approvals for one session."""
    with _lock:
        return [dict(entry.data) for entry in _gateway_queues.get(session_key, [])]


def register_gateway_settle(session_key: str, request_id: str, settle) -> bool:
    """Attach ``settle(reason)`` to one pending approval; it runs once when that wait ends by any path.
    False when the request is no longer pending (the surface should withdraw its prompt itself)."""
    with _lock:
        entry = _entry_for_request(session_key, request_id)
        if entry is None:
            return False
        entry.settle = settle
        return True


def ack_gateway_approval(session_key: str, request_id: str) -> bool:
    """A client's receipt of one approval request: True while that request is still pending."""
    with _lock:
        return _entry_for_request(session_key, request_id) is not None


def has_blocking_approval(session_key: str) -> bool:
    """Check if a session has one or more blocking gateway approvals waiting."""
    with _lock:
        return bool(_gateway_queues.get(session_key))


def pending_gateway_approval_count() -> int:
    """Unresolved gateway approvals across every session — a backend blocked on one is not idle."""
    with _lock:
        return sum(len(queue) for queue in _gateway_queues.values())


def get_pending_gateway_approval(session_key: str) -> dict | None:
    """Copy of the oldest unresolved gateway approval, for reconnecting clients
    to restore a prompt. Read-only snapshot — the queue stays authoritative."""
    if not session_key:
        return None
    with _lock:
        queue = _gateway_queues.get(session_key)
        if not queue:
            return None
        return dict(queue[0].data)


def clear_session(session_key: str) -> None:
    """Withdraw every pending approval and release the code kernels a session owns."""
    if not session_key:
        return
    with _lock:
        from tools.approval_notify_lease import revoke_session_locked
        revoke_session_locked(session_key)
        from tools.approval_gateway_wait import clear_held_denials
        clear_held_denials(session_key)
        for entry in _gateway_queues.pop(session_key, []):
            # Cancel blocked waits now so the old run unwinds instead of idling until timeout;
            # the prompt was withdrawn, nobody denied it.
            entry.cancelled = "the session ended before the prompt was answered"
            entry.event.set()
    from tools import mcp_action_gate, outbound_send_grant
    mcp_action_gate.clear_session(session_key)
    outbound_send_grant.clear_session(session_key)
    # Session-persistent code kernels (local and remote) share this owner key and die at the same boundary so a
    # finished conversation cannot leak a live interpreter.
    for module, shutdown in (("tools.code_kernel", "shutdown_kernels_for_owner"),
                             ("tools.code_kernel_remote", "shutdown_remote_kernels_for_owner")):
        try:
            getattr(importlib.import_module(module), shutdown)(session_key)
        except Exception:
            pass


# --- Result builders ------------------------------------------------------------------------------------------------

def _approved() -> dict:
    return {"approved": True, "message": None}


# ``outcome`` -> one plain sentence for the person who just answered (or did not), keyed as
# ``approval.summary.<outcome>`` (``approval.summary.default`` for unknown outcomes). ``message`` is
# addressed to the model ("Do NOT retry ..."); surfaces render ``user_summary`` first and fold the
# model text away, so a Reject click does not read like an error the user caused.
_USER_SUMMARY_OUTCOMES = frozenset({"denied", "timeout", "notify_failed", "cancelled", "blocked"})
# ``noun`` values (identifiers) -> ``approval.noun.<noun>`` for the human sentence.
_USER_SUMMARY_NOUNS = frozenset({"command", "code", "action"})


def _user_summary(outcome: str, noun: str = "command") -> str:
    from tools.approval_context import _get_approval_timeout, format_approval_window
    window = format_approval_window(_get_approval_timeout())
    key = f"approval.summary.{outcome}" if outcome in _USER_SUMMARY_OUTCOMES else "approval.summary.default"
    noun_text = t(f"approval.noun.{noun}") if noun in _USER_SUMMARY_NOUNS else noun
    return t(key, noun=noun_text, window=window)


def _denied(message: str, *, pattern_key: str, description: str, outcome: str, noun: str = "command",
            **extra) -> dict:
    """Standard non-consent result: the agent must not retry or rephrase. ``user_summary`` is the
    one-line human reading of the same outcome (see ``_user_summary``)."""
    return {"approved": False, "message": message, "pattern_key": pattern_key,
            "description": description, "outcome": outcome, "user_consent": False,
            "user_summary": _user_summary(outcome, noun), **extra}


def _blocked(message: str, *, pattern_key: str, description: str) -> dict:
    """Refusal with no consent keys: nobody was asked."""
    return {"approved": False, "message": message, "pattern_key": pattern_key, "description": description}


_SCAN_INCOMPLETE_BLOCK_MESSAGE = (
    "BLOCKED: this command is too long or complex for the guard to read to the end, so "
    "only a human may approve it, and {why}. Split it into smaller commands the guard can read, "
    "or ask the user to run it themselves. Do not run it from a file to get around this check."
)
_NO_REVIEWER_PRESENT = "no human is present to review it"


def _scan_incomplete_block(why: str) -> dict:
    """Refusal for a command the hardline scan could not finish where no human reviews it. Its hardline
    coverage is only the linear fallback, so nothing but a person may wave it through."""
    return _blocked(_SCAN_INCOMPLETE_BLOCK_MESSAGE.format(why=why),
                    pattern_key=_SCAN_INCOMPLETE_DESCRIPTION, description=_SCAN_INCOMPLETE_DESCRIPTION)


def _gateway_notify_cb(session_key: str):
    from tools.approval_notify_lease import current
    lease = current(session_key)
    if lease is not None:
        return lease.notify if lease.deliverable() else None
    with _lock:
        return _gateway_notify_cbs.get(session_key)


# --- Unattended contexts (nobody present to answer) -----------------------------------------------------------------

@dataclass(frozen=True)
class _Unattended:
    """One non-interactive context and the text its refusals use."""
    name: str       # "single_query" | "cron" | "unattended"
    cfg_key: str    # approvals.<cfg_key>: approve|deny
    clause: str     # "why nobody can approve" (lower-case sentence fragment)
    scope: str      # "in cron jobs" — completes "To allow ... {scope}"
    trust: str      # execute_code: "approve only if {trust}"

    def mode(self) -> str:
        # Looked up on the defining module at call time so tests patching the getters keep working.
        return getattr(approval_context, f"_get_{self.name}_approval_mode")()

    def block_message(self, subject: str, *, noun: str, advice: str) -> str:
        return (f"BLOCKED: {subject} but {self.clause}. {advice} To allow {noun} {self.scope}, set "
                f"approvals.{self.cfg_key}: approve in config.yaml.")

    @property
    def exec_tail(self) -> str:
        return (f"{self.clause[0].upper()}{self.clause[1:]}. Use normal tools "
                f"instead, or set approvals.{self.cfg_key}: approve only if {self.trust}.")


_SINGLE_QUERY_CTX = _Unattended(
    "single_query", "single_query_mode",
    "single-query mode (-q) runs without a user present to approve it",
    "in single-query mode", "this single-query run is intentionally trusted",
)
_CRON_CTX = _Unattended(
    "cron", "cron_mode", "cron jobs run without a user present to approve it",
    "in cron jobs", "this cron profile is intentionally trusted",
)


def _unattended_contexts() -> list[_Unattended]:
    """Active unattended contexts in evaluation order: single-query first (``hermes chat -q``
    exports HERMES_INTERACTIVE=1 but nobody answers); cron beats a platform marker because
    cron binds the platform for delivery routing only."""
    contexts = []
    if _is_single_query_approval_context():
        contexts.append(_SINGLE_QUERY_CTX)
    if _is_cron_approval_context():
        contexts.append(_CRON_CTX)
    elif _is_unattended_platform_approval_context():
        contexts.append(_Unattended(
            "unattended", "unattended_mode",
            "this session runs on an unattended platform "
            f"({_get_session_platform()}) with no user present to approve it",
            "on unattended platforms", "sessions on this surface are intentionally trusted",
        ))
    return contexts


def _auto_approving_turn() -> bool:
    """``hermes -z``: a one-shot whose submitter asked for an unattended turn, which the classic one-shot
    contract auto-approves past the floors."""
    from gateway.session_finite import unattended_turn
    return unattended_turn()


def _command_findings(command: str) -> list[tuple[str, str]]:
    """``[(pattern_key, description)]`` of what an unattended deny mode refuses; empty when clean. The first
    match plus every content-level rule (credential upload, invisible Unicode), so a pipe-to-shell cannot
    hide the credential upload in the same command. A command the hardline scan could not read to the end
    also carries the scan-incomplete finding."""
    is_dangerous, pattern_key, description = detect_dangerous_command(command)
    if not is_dangerous:
        return []
    findings = [(pattern_key, description)] + [
        (key, key) for key in detect_content_rule_keys(command) if key != pattern_key]
    if pattern_key != _SCAN_INCOMPLETE_DESCRIPTION and hardline_scan_incomplete(command):
        findings.append((_SCAN_INCOMPLETE_DESCRIPTION, _SCAN_INCOMPLETE_DESCRIPTION))
    return findings


def _unattended_deny(command: str, ctx: _Unattended) -> dict | None:
    """Deny-mode handling for one unattended context (cron / -q / webhook); None = allow."""
    if ctx.mode() != "deny":
        return None
    findings = _command_findings(command)
    if not findings:
        return None
    description = "; ".join(text for _, text in findings)
    result = {"approved": False, "message": ctx.block_message(
        f"Command flagged as dangerous ({description})", noun="dangerous commands",
        advice="Find an alternative approach that avoids this command.")}
    if ctx.name == "single_query":
        result.update(pattern_key=findings[0][0], description=description)
    return result


def _unattended_command_verdict(command: str) -> dict | None:
    """The refusal an unattended context applies to *command*, else None. Interactive contexts are never
    asked either: they have no refusal beyond the floors."""
    contexts = _unattended_contexts()
    if not contexts:
        return None
    if hardline_scan_incomplete(command):
        return _scan_incomplete_block(_NO_REVIEWER_PRESENT)
    if _auto_approving_turn():
        return None
    for ctx in contexts:
        result = _unattended_deny(command, ctx)
        if result is not None:
            return result
    return None


def unattended_write_refusal(subject: str) -> str | None:
    """The refusal an unattended context applies to a file write steering future agent behavior (``subject``
    names the targets), else None. Same ``cron_mode`` / ``single_query_mode`` / ``unattended_mode`` as a
    dangerous command: deny refuses, approve writes."""
    if _auto_approving_turn():
        return None
    for ctx in _unattended_contexts():
        if ctx.mode() == "deny":
            return ctx.block_message(
                f"Write to {subject}", noun="writes to files that steer agent behavior",
                advice="Do NOT retry it via another path (terminal, execute_code).")
    return None


# --- Owner decisions (outbound sends) ----------------------------------------------------------------------------------
# A draft that would send content out reaches its owner one way: gateway round-trip -> pending fallback -> CLI
# prompt. Silence is not consent, deny is a hard halt, and the answer covers that one operation.

GATEWAY_CHOICES = ["once", "deny"]
SEND_RULE_CHOICES = ["once", "always", "deny"]


def offered_choices(data: Mapping) -> list[str]:
    return list(SEND_RULE_CHOICES if data.get("choices") == SEND_RULE_CHOICES else GATEWAY_CHOICES)


@dataclass(frozen=True)
class _GateSpec:
    noun: str                 # "message" — for the pending result and the human summary
    # Message templates; ``{reason}{reason_addendum}{timeout_addendum}`` fill ``gateway_refused``.
    notify_failed: str
    gateway_refused: str
    cli_timeout: str
    cli_denied: str
    editable: bool = False


# The only answer that counts as consent. Anything not listed is refused, so a renamed field, a truncated payload
# or a plugin bug fails closed instead of open.
CONSENT_ANSWERS = frozenset({"once"})

# Platform adapters do not all speak the canonical vocabulary, so normalize BEFORE the allow-list rather than
# widening it: case and surrounding whitespace, and affirmative aliases. The WhatsApp Cloud adapter's Approve
# button emits a literal "approve". A client built before approvals became one operation at a time may still
# answer "session" or "always"; that is one operation too. "always" also saves a rule, only on a card that offered it.
_CHOICE_ALIASES = {"approve": "once", "approved": "once", "allow": "once", "session": "once", "always": "once"}


def canonical_approval_choice(choice):
    """Normalize a platform adapter's approval answer onto the canonical vocabulary."""
    if not isinstance(choice, str):
        return ""  # a JSON list/object/number is no decision; "" is refused, and hashable for the checks
    normalized = choice.strip().lower()
    return _CHOICE_ALIASES.get(normalized, normalized)


_UNRECOGNIZED_ANSWER = (
    "BLOCKED: the approval response was not a recognized decision (expected once to approve, or deny to "
    "refuse). An unrecognized answer is treated as NO consent. Do NOT retry this action, do NOT rephrase it, "
    "and do NOT attempt the same outcome via a different route — report the failed approval to the user instead."
)

_STOP_DRAFT = (
    " The message was NOT sent. Do NOT retry it, do NOT rephrase it, and do NOT deliver the same "
    "message through another tool or route."
)
_DRAFT_GATE = _GateSpec(
    noun="message",
    notify_failed="BLOCKED: The draft could not be shown to the owner." + _STOP_DRAFT,
    gateway_refused="BLOCKED: The draft {reason}.{reason_addendum}" + _STOP_DRAFT + "{timeout_addendum}",
    cli_timeout="BLOCKED: The draft timed out without a decision." + _STOP_DRAFT + " Silence is not consent.",
    cli_denied="BLOCKED: The owner discarded this draft." + _STOP_DRAFT,
    editable=True,
)


def _pending_result(spec: _GateSpec, session_key: str, *, command: str, description: str,
                    pattern_key: str, gateway: bool) -> dict:
    """Result for a question nobody can answer right now (no gateway notifier, no CLI panel): a
    fail-closed denial for a gateway background child no chat can prompt for (#133514), else
    ``approval_required``."""
    from tools.approval_notify_lease import stranded_denial
    if (denied := stranded_denial(session_key, gateway, spec.noun, pattern_key, description)) is not None:
        return denied
    return {
        "approved": False, "pattern_key": pattern_key, "status": "approval_required",
        "command": command, "description": description,
        "message": (f"⚠️ This action is potentially dangerous ({description}). "
                    f"Asking the user for approval.\n\n**Target:**\n```\n{command}\n```"),
    }


def _with_edit(spec: _GateSpec, decision: dict, result: dict) -> dict:
    if spec.editable and decision.get("edited_text") is not None:
        result["edited_text"] = decision["edited_text"]
    return result


def _human_decision(spec: _GateSpec, *, command: str, description: str, pattern_key: str,
                    session_key: str, approval_callback, is_cli: bool, is_gateway: bool, is_ask: bool,
                    extra_data: dict | None = None, rule: "SendRuleCandidate | None" = None) -> dict:
    """Ask the owner and turn the answer into the gate result. Consent is once or deny."""
    from agent.redact import redact_approval_display

    def deny(template: str, outcome: str, **fmt) -> dict:
        deny_reason = fmt.pop("deny_reason", None)
        extra = {"deny_reason": deny_reason} if "reason" in fmt else {}
        return _denied(template.format(description=description, **fmt),
                       pattern_key=pattern_key, description=description,
                       outcome=outcome, noun=spec.noun, **extra)

    def grant(choice: str) -> dict:
        # Consent is an allow-list, not a deny-list: normalize the answer, then refuse anything
        # that is not one of CONSENT_ANSWERS rather than executing it.
        choice = canonical_approval_choice(choice)
        if choice not in CONSENT_ANSWERS:
            logger.warning("approval: refusing unrecognized approval answer %r (pattern_key=%s, session=%s)",
                           choice, pattern_key, session_key)
            return _denied(_UNRECOGNIZED_ANSWER, pattern_key=pattern_key,
                           description=description, outcome="unrecognized_answer", noun=spec.noun)
        return _approved()

    # Gateway/async approval: block the agent thread until the owner answers, mirroring the CLI's synchronous
    # input() flow. The agent never sees "approval_required" here — it gets a result or a definitive BLOCKED.
    if is_gateway or is_ask:
        notify_cb = _gateway_notify_cb(session_key)
        if notify_cb is not None:
            data = {
                "command": redact_approval_display(command), "pattern_key": pattern_key,
                "pattern_keys": [pattern_key], "description": redact_approval_display(description),
                "choices": SEND_RULE_CHOICES if rule else GATEWAY_CHOICES, **(extra_data or {}),
            }
            decision = _await_gateway_decision(session_key, notify_cb, data, surface="gateway",
                                              identity=f"{pattern_key}\n{description}\n{command}")
            if decision.get("notify_failed"):
                return _denied(spec.notify_failed, pattern_key=pattern_key,
                               description=description, outcome="notify_failed", noun=spec.noun)
            # Consent contract: silence is NOT consent, and an explicit deny is a hard halt, both BLOCKED.
            choice, deny_reason = decision["choice"], decision.get("reason")
            held = decision.get("held")
            if decision.get("cancelled"):
                # The prompt was withdrawn (turn interrupted or ended) before anyone answered:
                # still fail closed, but do not attribute a refusal to the user.
                return deny(spec.gateway_refused, "cancelled",
                            reason=f"approval was withdrawn before the user answered ({decision['cancelled']})",
                            reason_addendum="", timeout_addendum="", deny_reason=None)
            if not decision["resolved"]:
                return deny(spec.gateway_refused, "timeout", reason="timed out without user response",
                            reason_addendum="", timeout_addendum=" Silence is not consent.",
                            deny_reason=deny_reason)
            if held:
                return deny(spec.gateway_refused, "denied", reason="denied by user earlier in this turn",
                            reason_addendum=" Wait for the user's next message before asking again.",
                            timeout_addendum="", deny_reason=None)
            if choice is None or choice == "deny":
                return deny(spec.gateway_refused, "denied", reason="denied by user",
                            reason_addendum=(f' Reason given by the user: "{deny_reason}".' if deny_reason else ""),
                            timeout_addendum="", deny_reason=deny_reason)
            result = grant(choice)
            if rule is not None and result["approved"] and decision.get("remember"):
                _save_send_rule(rule)
            return _with_edit(spec, decision, result)

        # No gateway callback (cron, batch, or a gateway marker leaked into an interactive CLI, historically via
        # `import gateway.run`): paint the local panel when possible instead of a result that makes the agent
        # look "auto-blocked".
        if not _should_fall_through_to_cli_approval(
            is_cli=is_cli, approval_callback=approval_callback, notify_cb=notify_cb,
        ):
            return _pending_result(spec, session_key, command=command, description=description,
                                   pattern_key=pattern_key, gateway=is_gateway)

    # CLI interactive: single combined prompt, wrapped in the pre/post plugin hooks.
    hook_kwargs = dict(command=command, description=description, pattern_key=pattern_key,
                       pattern_keys=[pattern_key], session_key=session_key, surface="cli")
    approval_context._fire_approval_hook("pre_approval_request", **hook_kwargs)
    choice = prompt_dangerous_approval(command, description, approval_callback=approval_callback)
    approval_context._fire_approval_hook("post_approval_response", **hook_kwargs, choice=choice)
    if choice == "timeout":
        return deny(spec.cli_timeout, "timeout")
    if choice == "cancelled":
        # The prompt never reached a human (callback raised, no callback under prompt_toolkit, interrupted
        # read): fail closed, but do not attribute a refusal to the user (#22992).
        return deny(spec.gateway_refused, "cancelled",
                    reason="was not approved: the approval prompt could not be delivered or was not answered "
                           f"({getattr(choice, 'cause', 'no answer')})",
                    reason_addendum="", timeout_addendum=" Silence is not consent.", deny_reason=None)
    if choice == "deny":
        return deny(spec.cli_denied, "denied")
    return grant(choice)


def _save_send_rule(rule: "SendRuleCandidate") -> None:
    from tools import send_rules
    try:
        send_rules.remember(rule)
    except (OSError, ValueError) as exc:
        logger.warning("send rule not saved (%s); this send is still approved", type(exc).__name__)


def _presence(approval_callback=None) -> tuple:
    """``(approval_callback, is_cli, is_gateway, is_ask)`` for the current context.

    Single-query ``-q`` and cron clear the presence trio: ``hermes chat -q`` exports
    HERMES_INTERACTIVE=1 for sudo prompts, and a gateway sets HERMES_EXEC_ASK=1 at startup and
    passes its environ to every external cron worker (#110932) — in neither can a human answer
    the card. Unattended *platforms* keep ``is_ask`` only while a client on the session
    could actually answer: ``/v1/runs`` and streaming chat completions bridge an approval
    notifier (``approval.request``), so on api_server a registered notifier is the discriminator.
    webhook/msgraph_webhook turns run through the generic TurnRunner lane, which registers a notifier
    for *every* turn — but those adapters render no approval surface and the inbound lane has no
    reader, so there ``is_ask`` drops regardless (#100532)."""
    approval_callback = _resolve_cli_approval_callback(approval_callback)
    is_cli, is_gateway = _is_interactive_cli(), _is_gateway_approval_context()
    is_ask = env_var_enabled("HERMES_EXEC_ASK")
    if _is_single_query_approval_context() or _is_cron_approval_context():
        is_cli = is_gateway = is_ask = False
    elif is_ask and _is_unattended_platform_approval_context() \
            and (_gateway_notify_cb(get_current_session_key()) is None
                 or _get_session_platform() in approval_context._NOTIFIER_BLIND_APPROVAL_PLATFORMS):
        is_ask = False
    return approval_callback, is_cli, is_gateway, is_ask


def request_draft_approval(*, text: str, description: str, pattern_key: str, draft: dict,
                           details: list[dict] | None = None, approval_callback=None, subject: str = "",
                           attachments: tuple[str, ...] = (), rule: "SendRuleCandidate | None" = None) -> dict:
    from tools import approval_card_text
    from tools.details_bubble import post_details
    approval_callback, is_cli, is_gateway, is_ask = _presence(approval_callback)
    card = approval_card_text.card_fields(approval_card_text.owner_language())
    if is_gateway or is_ask:
        post_details(approval_card_text.bubble(draft, text, subject, attachments, card["language"]))
    return _human_decision(
        _DRAFT_GATE, command=text, description=description, pattern_key=pattern_key,
        session_key=get_current_session_key(), approval_callback=approval_callback,
        is_cli=is_cli, is_gateway=is_gateway, is_ask=is_ask,
        extra_data={"draft": draft, "details": details or [], **card}, rule=rule,
    )


# --- Guards ---------------------------------------------------------------------------------------------------------

def _profile_creation_refusal(source: str, *, is_code: bool = False) -> dict | None:
    from hermes_cli.profile_admin_guard import CREATE_REFUSED_MESSAGE
    if not creates_bot_or_profile(source, code=is_code):
        return None
    if approver_present() and not is_background_review():
        logger.info("bot creation approved by the owner turn")
        return None
    logger.warning("Refused an agent-run bot or profile creation")
    return _blocked(CREATE_REFUSED_MESSAGE, pattern_key="human_required:create", description=CREATE_REFUSED_MESSAGE)


def _should_skip_container_guards(env_type: str, has_host_access: bool = False) -> bool:
    """True when the backend is isolated enough to skip dangerous-command checks. Docker is the
    exception once host paths are bind-mounted: ``rm -rf /workspace`` then reaches host files."""
    if env_type == "docker":
        return not has_host_access
    if env_type in ("modal", "daytona", "vercel_sandbox"):
        return True
    # Plugin backends declare the same classification through the provider ABI (#94400);
    # fail-soft to False so an unknown or raising backend — or a raising registry
    # lookup — keeps the guards on rather than propagating out of the predicate.
    try:
        from agent.terminal_env_registry import provider_flag
        return bool(provider_flag(env_type, "skip_container_guards", False))
    except Exception:
        return False


def _user_deny_block(command: str) -> dict | None:
    """The operator's ``approvals.deny`` rules are never bypassable, not even by an isolated container:
    they express intent about what the agent may DO, not what it can reach, so they are evaluated
    before the container fast path."""
    deny_pattern = _match_user_deny_rule(command)
    if deny_pattern is None:
        return None
    logger.warning("User deny rule %r blocked command: %s", deny_pattern, command[:200])
    return _user_deny_block_result(deny_pattern)


def _floor_block(command: str, *, sudo_guard: bool = False) -> dict | None:
    """Unconditional floors, BEFORE any unattended approve-mode so no setting can bypass them:
    hardline catastrophic commands, password-piping to ``sudo -S`` with no SUDO_PASSWORD configured
    (full guard only), the user's own approvals.deny rules, and deletion of the Python
    interpreter/venv this very runtime boots from (a delete the agent cannot walk back — the next
    start fails before any tool can run, #58748)."""
    from agent.runtime_self_protection import command_deletes_runtime

    is_hardline, hardline_desc = detect_hardline_command(command)
    if is_hardline:
        logger.warning("Hardline block: %s (command: %s)", hardline_desc, command[:200])
        return _hardline_block_result(hardline_desc, command)
    runtime_target = command_deletes_runtime(command)
    if runtime_target:
        logger.warning("Runtime self-delete block: %s (command: %s)", runtime_target, command[:200])
        return _hardline_block_result(f"recursive/any delete of {runtime_target}", command)
    if sudo_guard:
        is_sudo_guess, sudo_guess_desc = _check_sudo_stdin_guard(command)
        if is_sudo_guess:
            logger.warning("Sudo stdin guard block: %s (command: %s)", sudo_guess_desc, command[:200])
            return _sudo_stdin_block_result(sudo_guess_desc)
    return _user_deny_block(command)


def check_dangerous_command(command: str, env_type: str, has_host_access: bool = False) -> dict:
    """Pattern layer of the command guard. ``has_host_access``: a Docker sandbox that bind-mounts
    host paths must not skip the checks.
    Returns ``{"approved": True/False, "message": str or None, ...}``."""
    if _should_skip_container_guards(env_type, has_host_access=has_host_access):
        return _user_deny_block(command) or _approved()
    return (_floor_block(command) or _profile_creation_refusal(command)
            or _unattended_command_verdict(command) or _approved())


def check_all_command_guards(command: str, env_type: str, has_host_access: bool = False) -> dict:
    """Run all pre-exec checks and return a single decision: floors, the bot/profile create refusal, then
    the refusal an unattended context applies. Plugins that want to veto a command do it from
    ``pre_tool_call``. ``has_host_access``: a Docker sandbox with bind-mounted host paths takes the
    normal flow."""
    if _should_skip_container_guards(env_type, has_host_access=has_host_access):
        return _user_deny_block(command) or _approved()
    blocked = _floor_block(command, sudo_guard=True) or _profile_creation_refusal(command)
    if blocked is not None:
        return blocked
    from tools.tainted_turn_gate import spend_call_grant
    if spend_call_grant("terminal"):
        return _approved()
    return _unattended_command_verdict(command) or _approved()


_EXECUTE_CODE_DESCRIPTION = (
    "execute_code script execution. The script can spawn subprocesses or "
    "mutate files without passing through terminal command checks."
)


def check_execute_code_guard(code: str, env_type: str, has_host_access: bool = False) -> dict:
    """Check an execute_code script before its child process is spawned.

    The script can call ``subprocess``/``os.system``/``ctypes`` directly, none of which pass
    through ``terminal()`` / ``DANGEROUS_PATTERNS``. It runs unless it creates a bot or profile outside
    the owner's own turn, or the first active unattended context (-q, cron, unattended platform) is in
    deny mode. The hardline floor still blocks catastrophic ``terminal()`` commands the script issues.
    Same dict contract as ``check_all_command_guards``.
    """
    # Isolated backends already sandbox the child.
    if _should_skip_container_guards(env_type, has_host_access=has_host_access):
        return _approved()
    refusal = _profile_creation_refusal(code, is_code=True)
    if refusal is not None:
        return refusal
    if _auto_approving_turn():
        return _approved()
    ctx = next(iter(_unattended_contexts()), None)
    if ctx is not None and ctx.mode() == "deny":
        return _denied(
            "BLOCKED: execute_code runs arbitrary local Python (including "
            "subprocess calls that bypass shell-string checks). " + ctx.exec_tail,
            pattern_key="execute_code", description=_EXECUTE_CODE_DESCRIPTION, outcome="blocked", noun="code",
        )
    return _approved()
