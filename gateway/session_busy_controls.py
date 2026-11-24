"""Session-scoped busy preferences and controls of the existing execution only."""
from functools import partial
from pathlib import Path

from persistence.core.errors import AuthorityRefusal


def handlers(connection):
    return {
        'config.get': partial(busy_config, connection),
        'config.set': partial(busy_config, connection, write=True),
        'session.steer': partial(correct, connection, verb='steer'),
        'session.redirect': partial(correct, connection, verb='redirect'),
    }


def authorize(connection, ref, params, capability):
    connection.authority.authorize(connection.actor, ref, capability)
    _require_own_profile(connection, params)


def authorize_profile(connection, params, capability):
    """``authorize`` for a verb that belongs to the profile, not to one session: the same serving,
    profile and capability checks with no session lookup."""
    from gateway.session_authorities import require_serving
    authority, actor = connection.authority, connection.actor
    require_serving(authority)
    if actor.profile_id != authority.profile_id:
        raise AuthorityRefusal('profile_mismatch')
    if capability not in actor.capabilities:
        raise AuthorityRefusal('permission_denied')
    _require_own_profile(connection, params)


def _require_own_profile(connection, params):
    # The contract's ``profile`` is nullable; null means this owner, as an omitted key does.
    if params.get('profile') is not None:
        from hermes_cli.profiles import profile_matches_home
        profile = params['profile']
        if not isinstance(profile, str):
            raise AuthorityRefusal('invalid_params')
        if profile and not profile_matches_home(profile, Path(connection.authority.profile_id)):
            raise AuthorityRefusal('profile_mismatch')


async def busy_config(connection, ref, params, *, write=False):
    if write and params.get('key') == 'model':
        # The legacy picker verb. On the owner a model pick is ``session.mutate`` operation=model
        # (revision-fenced, retry-idempotent, selection-guarded); a config write would bypass all
        # three. Refused before authorization or any read: nothing is written or deferred.
        raise AuthorityRefusal('use_session_mutation_model')
    allowed = {'session_id', 'profile', 'key'} | ({'value'} if write else set())
    if params.get('key') == 'verbose' and not set(params) - allowed and ref.session_id:
        return verbose_config(connection, ref, params, write)
    if params.get('key') == 'show_reasoning' and not set(params) - allowed and ref.session_id:
        return show_reasoning_config(connection, ref, params, write)
    if params.get('key') == 'service_tier' and write and not set(params) - allowed and ref.session_id:
        return service_tier_config(connection, ref, params)
    if (set(params) - allowed or not ref.session_id or params.get('key') != 'busy'
            or (write and params.get('value') not in ('interrupt', 'steer', 'queue'))):
        raise AuthorityRefusal('invalid_params')
    authorize(connection, ref, params, 'session:control' if write else 'session:read')
    authority = connection.authority
    live = authority.sessions[ref.session_id]
    if write:
        # UI negotiation is not a settings write and must not rebuild frozen
        # launch policy, toolsets, history, or the retained AIAgent.
        live.busy_input_mode = params['value']
    value = getattr(live, 'busy_input_mode', None)
    if value is None:
        from gateway.session_policy import policy_for_source
        policy = policy_for_source(authority.runner, live.source)
        # Main's TUI defaulted to ``queue`` (``ui-tui/src/app/useConfigSync.ts`` TUI_BUSY_DEFAULT): in a
        # full-screen composer the next prompt is authored while the agent streams, and an unintended
        # interrupt loses work. Only an explicit ``display.busy_input_mode`` overrides it; every other
        # surface keeps the framework default ``interrupt``.
        fallback = 'queue' if policy is not None and getattr(policy, 'source', None) == 'tui' else 'interrupt'
        display = (policy.config().get('display') or {}) if policy else {}
        value = (display.get('busy_input_mode') or fallback if policy else
                 authority.runner._effective_busy_input_mode(live.source))
        if value not in ('interrupt', 'steer', 'queue'):
            value = fallback
    return {'key': 'busy', 'value': value, 'scope': 'session'}


_VERBOSE_CYCLE = ('off', 'new', 'all', 'verbose')


def verbose_config(connection, ref, params, write):
    """Session-scoped /verbose: the tool-progress mode the next tool events of
    this session render with (read by TurnRunner), like busy never a settings write."""
    value = params.get('value')
    if write and value not in (*_VERBOSE_CYCLE, 'cycle'):
        raise AuthorityRefusal('invalid_params')
    authorize(connection, ref, params, 'session:control' if write else 'session:read')
    live = connection.authority.sessions[ref.session_id]
    current = getattr(live, 'tool_progress_mode', None) or 'all'
    if write:
        live.tool_progress_mode = current = (
            _VERBOSE_CYCLE[(_VERBOSE_CYCLE.index(current) + 1) % 4] if value == 'cycle' else value)
    return {'key': 'verbose', 'value': current, 'scope': 'session'}


def show_reasoning_config(connection, ref, params, write):
    """Session-scoped reasoning display (the classic CLI's ``/reasoning show|hide`` and verbose
    reasoning): whether a local-viewer turn of this session streams ``reasoning.delta``. Unset, it
    reports the launch default the turn uses. Never a settings write."""
    value = params.get('value')
    word = str(value).strip().lower()
    if write and word not in _BOOL_WORDS:
        raise AuthorityRefusal('invalid_params')
    authorize(connection, ref, params, 'session:control' if write else 'session:read')
    live = connection.authority.sessions[ref.session_id]
    if write:
        live.show_reasoning = _BOOL_WORDS[word]
    shown = getattr(live, 'show_reasoning', None)
    if shown is None:
        from gateway.local_viewer_events import launch_shows_reasoning
        from gateway.session_policy import policy_for_source
        shown = launch_shows_reasoning(policy_for_source(connection.authority.runner, live.source),
                                       connection.authority)
    return {'key': 'show_reasoning', 'value': '1' if shown is True else '0', 'scope': 'session'}


def service_tier_config(connection, ref, params):
    """Session-scoped ``/fast`` (the classic CLI's tier pick, ``normal`` clears to normal): the
    session's service-tier override the next turn's agent reads (``current_service_tier``), never a
    settings write. ``--global`` persistence stays the client's own config.yaml write."""
    from agent.fast_mode import parse_exact_service_tier
    try:
        tier = parse_exact_service_tier(params.get('value')) if isinstance(params.get('value'), str) else None
    except ValueError:
        tier = None
    if tier is None:
        raise AuthorityRefusal('invalid_params')
    authorize(connection, ref, params, 'session:control')
    live = connection.authority.sessions[ref.session_id]
    connection.authority.runner._set_session_service_tier_override(live.route, tier or None)
    live.event_stream.publish(ref.session_id, {'service_tier': tier or ''}, event_type='session.info')
    return {'key': 'service_tier', 'value': tier or 'normal', 'scope': 'session'}


_BOOL_WORDS = {'1': True, 'on': True, 'true': True, '0': False, 'off': False, 'false': False}


def adopts_owner_agent(authority, ref):
    """The claimed turn runs an in-process owner agent, which adopt_agent hands latched steers to;
    a cron job or a managed worker has no steer seam, so a latch there would be acknowledged and lost."""
    from gateway.session_managed_worker import managed_policy
    from gateway.session_policy import policy_for_source
    try:
        policy = policy_for_source(authority.runner, authority.sessions[ref.session_id].source)
        return not (policy is not None and policy.source == 'cron') and managed_policy(authority, ref) is None
    except AuthorityRefusal:
        return False


async def correct(connection, ref, params, *, verb):
    if (set(params) - {'session_id', 'profile', 'text', 'execution_generation'}
            or not isinstance(params.get('text'), str) or not params['text'].strip()
            or type(params.get('execution_generation')) is not int):
        raise AuthorityRefusal('invalid_params')
    authorize(connection, ref, params, 'session:control')
    # TUI-26: text typed during a running turn in Ink's interrupt/steer busy modes arrives here, not
    # at prompt.submit. A bare stop phrase in a LOCAL voice chat ends the chat and reaches no agent,
    # whatever generation is running.
    voice_stop = getattr(connection, '_typed_voice_stop', None)
    if voice_stop is not None and await voice_stop(ref, params):
        return {'voice_stopped': True}
    authority = connection.authority
    generation = params['execution_generation']
    live = authority.sessions[ref.session_id]
    with live.event_stream.lock:
        authority.check_approval_generation(ref.session_id, generation)
        # Managed workers have a separate control channel, not a cached owner
        # agent. Refuse explicitly instead of acknowledging undeliverable text.
        if ref.session_id in getattr(authority, '_managed_workers', {}):
            raise AuthorityRefusal('unsupported_control')
        # Accepted for this exact claim before its turn built an agent: steer_agent latches it for
        # the agent this generation adopts, never a later one.
        agent, latched = authority.steer_agent(ref, generation, params['text'] if verb == 'steer' else None)
        if latched:
            return {'status': 'queued', 'text': params['text'], 'execution_generation': generation,
                    'authority_epoch': authority.epoch}
        # A claim can outlive the agent that carried it (a reaped turn the client still believes is
        # running), and a redirect in the build window has no agent to queue behind. Nothing live can
        # take the text, so answer 'rejected' — the wire contract's "not corrected, queue it as the
        # next prompt" (desktop SessionRedirectResponse, tui_gateway's idle-steer reply). Raising here
        # made clients discard the message (#141644). ``delivered: False`` is the confirmation a
        # client may re-admit on: the live-agent 'rejected' below can follow delivery.
        if agent is None:
            return {'status': 'rejected', 'text': params['text'], 'execution_generation': generation,
                    'authority_epoch': authority.epoch, 'delivered': False}
        method = getattr(agent, verb, None)
        if not callable(method):
            raise AuthorityRefusal('execution_not_ready')
        accepted = method(params['text'])
        return {'status': ({'steer': 'queued', 'redirect': 'redirected'}[verb] if accepted else 'rejected'),
                'text': params['text'], 'execution_generation': generation,
                'authority_epoch': authority.epoch}
