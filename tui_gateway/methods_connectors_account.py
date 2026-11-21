from tui_gateway.contracts.connectors import ConnectorErrorReason

from .method_ctx import HandlerRegistry, bind_module

_registry = HandlerRegistry()
method = _registry.method
_profile_scoped = _registry.profile_scoped


@method("connectors.catalog")
@_profile_scoped
def _(rid, _params):
    from hermes_cli.pal_connectors import load_pal_connectors
    from tui_gateway.contracts.connectors import ConnectorsCatalogResult

    rows = [_catalog_row(entry) for entry in load_pal_connectors()]
    return _ok(rid, ConnectorsCatalogResult(connectors=rows).model_dump(mode="json"))


def _catalog_row(entry):
    from hermes_cli.pal_connectors import FEATURED_CONNECTOR_IDS
    from tools.connectors.gateway_client_id import UNAVAILABLE_MESSAGE
    from tui_gateway.contracts.connectors import ConnectorCatalogRow, ConnectorCatalogStatus

    from tui_gateway.connector_setup_guide import build_guide, derive_progress
    from tui_gateway.mcp_account_rpc import account_rows

    accounts = account_rows(entry.id) if entry.multi_account else []
    status = _catalog_status(entry, accounts)
    return ConnectorCatalogRow(
        slug=entry.id, name=entry.name, description=entry.description, category=entry.category, icon=entry.icon,
        method=entry.method.value, verified=entry.verified, mcp_url=entry.mcp_url, source=entry.source, status=status,
        notes=UNAVAILABLE_MESSAGE if entry.cimd and status is ConnectorCatalogStatus.needs_setup else entry.notes, setup_guide=build_guide(entry), setup_progress=derive_progress(entry),
        featured=entry.id in FEATURED_CONNECTOR_IDS, multi_account=entry.multi_account, accounts=accounts,
        sign_in=entry.sign_in.value,
    )


def _catalog_status(entry, accounts):
    from hermes_cli import mcp_catalog
    from hermes_cli.pal_connectors import ConnectionMethod
    from tools.mcp_oauth import pending_reauth_reason
    from tui_gateway.contracts.connectors import ConnectorCatalogStatus
    from tui_gateway.mcp_account_rpc import aggregate_status

    if entry.method is ConnectionMethod.OAUTH_CLIENT:
        from tui_gateway.oauth_client_rpc import oauth_client_status
        status = oauth_client_status(entry)
        aggregate = aggregate_status(accounts) if status is not ConnectorCatalogStatus.needs_setup else None
        return ConnectorCatalogStatus(aggregate) if aggregate else status
    if aggregate := aggregate_status(accounts):
        return ConnectorCatalogStatus(aggregate)
    if not mcp_catalog.is_enabled(entry.id):
        return ConnectorCatalogStatus.needs_setup if _needs_public_address(entry) else ConnectorCatalogStatus.not_connected
    if pending_reauth_reason(entry.id):
        return ConnectorCatalogStatus.needs_reconnect
    return ConnectorCatalogStatus.connected


def _needs_public_address(entry):
    from hermes_constants import get_hermes_home
    from tools.connectors.gateway_client_id import public_base
    return entry.cimd and public_base(get_hermes_home()) is None


def _details_call(params_model, action):
    def handler(rid, params):
        from pydantic import ValidationError
        from tui_gateway import connector_details as details
        from tui_gateway.contracts.connectors import ConnectorErrorReason
        try:
            request = params_model.model_validate(params)
        except ValidationError:
            return _connector_rpc_error(rid, 4000, ConnectorErrorReason.invalid_params, "Connector parameters are invalid.")
        try:
            return _ok(rid, action(details, request).model_dump(mode="json", exclude_none=True))
        except details.DetailsRpcError as exc:
            return _connector_rpc_error(rid, exc.code, exc.reason, exc.message)
    return handler


@method("connectors.details")
@_profile_scoped
def _(rid, params):
    from tui_gateway.contracts.connectors import ConnectorDetailsParams
    return _details_call(ConnectorDetailsParams, lambda details, request: details.details(request.slug))(rid, params)


@method("connectors.details.policy.set")
@_profile_scoped
def _(rid, params):
    from tui_gateway.contracts.connectors import ConnectorDetailsPolicySetParams
    return _details_call(
        ConnectorDetailsPolicySetParams,
        lambda details, request: details.set_mode(request.slug, request.group.value, request.mode.value))(rid, params)


def _oauth_client_call(params_model, action):
    def handler(rid, params):
        from pydantic import ValidationError
        from tui_gateway import oauth_client_rpc as rpc
        try:
            request = params_model.model_validate(params)
        except ValidationError:
            return _connector_rpc_error(rid, 4000, ConnectorErrorReason.invalid_params, "slug is required.")
        try:
            return _ok(rid, action(rpc, request).model_dump(mode="json"))
        except rpc.OAuthClientRpcError as exc:
            return _connector_rpc_error(rid, exc.code, exc.reason, exc.message)
    return handler


@method("connectors.oauth_client.setup")
@_profile_scoped
def _(rid, params):
    from tui_gateway.contracts.connectors import OAuthClientSlugParams
    return _oauth_client_call(OAuthClientSlugParams, lambda rpc, request: rpc.setup(request.slug))(rid, params)


@method("connectors.oauth_client.save")
@_profile_scoped
def _(rid, params):
    from tui_gateway.contracts.connectors import OAuthClientSaveParams
    return _oauth_client_call(OAuthClientSaveParams, lambda rpc, request: rpc.save(request))(rid, params)


@method("connectors.oauth_client.connect")
@_profile_scoped
def _(rid, params):
    from tui_gateway.contracts.connectors import OAuthClientConnectParams
    return _oauth_client_call(OAuthClientConnectParams, lambda rpc, request: rpc.connect(request))(rid, params)


@method("connectors.oauth_client.remove")
@_profile_scoped
def _(rid, params):
    from tui_gateway.contracts.connectors import OAuthClientRemoveParams
    return _oauth_client_call(OAuthClientRemoveParams, lambda rpc, request: rpc.remove(request))(rid, params)


@method("connectors.setup.check")
@_profile_scoped
def _(rid, params):
    from pydantic import ValidationError
    from tui_gateway.connector_setup_guide import SetupCheckRpcError, run_setup_check
    from tui_gateway.contracts.connectors import ConnectorSetupCheckParams
    try:
        request = ConnectorSetupCheckParams.model_validate(params)
    except ValidationError:
        return _connector_rpc_error(rid, 4000, ConnectorErrorReason.invalid_params, "slug and values are required.")
    try:
        return _ok(rid, run_setup_check(request).model_dump(mode="json"))
    except SetupCheckRpcError as exc:
        return _connector_rpc_error(rid, exc.code, exc.reason, exc.message)


def _setup_progress_call(params_model, action):
    def handler(rid, params):
        from pydantic import ValidationError
        from tui_gateway.connector_setup_guide import SetupCheckRpcError
        from tui_gateway.contracts.connectors import ConnectorErrorReason
        try:
            request = params_model.model_validate(params)
        except ValidationError:
            return _connector_rpc_error(rid, 4000, ConnectorErrorReason.invalid_params, "Setup progress holds step ids only.")
        try:
            return _ok(rid, action(request).model_dump(mode="json"))
        except SetupCheckRpcError as exc:
            return _connector_rpc_error(rid, exc.code, exc.reason, exc.message)
    return handler


@method("connectors.setup.progress.get")
@_profile_scoped
def _(rid, params):
    from tui_gateway.connector_setup_guide import get_setup_progress
    from tui_gateway.contracts.connectors import SetupProgressGetParams
    return _setup_progress_call(SetupProgressGetParams, get_setup_progress)(rid, params)


@method("connectors.setup.progress.set")
@_profile_scoped
def _(rid, params):
    from tui_gateway.connector_setup_guide import set_setup_progress
    from tui_gateway.contracts.connectors import SetupProgressSetParams
    return _setup_progress_call(SetupProgressSetParams, set_setup_progress)(rid, params)


def _discord_call(params_model, action):
    def handler(rid, params):
        from pydantic import ValidationError
        from tui_gateway import discord_connector as discord
        try:
            request = params_model.model_validate(params)
        except ValidationError:
            return _connector_rpc_error(rid, 4000, ConnectorErrorReason.invalid_params, "Discord parameters are invalid.")
        try:
            return _ok(rid, action(discord, request).model_dump(mode="json"))
        except discord.DiscordRpcError as exc:
            return _connector_rpc_error(rid, exc.code, exc.reason, exc.message)
    return handler


@method("connectors.discord.token")
@_profile_scoped
def _(rid, params):
    from tui_gateway.contracts.connectors import DiscordTokenParams
    return _discord_call(DiscordTokenParams, lambda discord, request: discord.save_token(request.item))(rid, params)


@method("connectors.discord.guilds")
@_profile_scoped
def _(rid, params):
    from tui_gateway.contracts.common import ProfileParams
    return _discord_call(ProfileParams, lambda discord, _request: discord.guilds())(rid, params)


@method("connectors.discord.save")
@_profile_scoped
def _(rid, params):
    from tui_gateway.contracts.connectors import DiscordSaveParams
    return _discord_call(DiscordSaveParams, lambda discord, request: discord.save(request.guild_ids, request.read_only))(
        rid, params)


def _google_ads_call(params_model, action):
    def handler(rid, params):
        from pydantic import ValidationError
        from tui_gateway import google_ads_connector as ads
        try:
            request = params_model.model_validate(params)
        except ValidationError:
            return _connector_rpc_error(rid, 4000, ConnectorErrorReason.invalid_params, "Google Ads parameters are invalid.")
        try:
            return _ok(rid, action(ads, request).model_dump(mode="json"))
        except ads.GoogleAdsRpcError as exc:
            return _connector_rpc_error(rid, exc.code, exc.reason, exc.message)
    return handler


@method("connectors.google_ads.status")
@_profile_scoped
def _(rid, params):
    from tui_gateway.contracts.common import ProfileParams
    return _google_ads_call(ProfileParams, lambda ads, _request: ads.status())(rid, params)


@method("connectors.google_ads.save")
@_profile_scoped
def _(rid, params):
    from tui_gateway.contracts.connectors import GoogleAdsSaveParams
    return _google_ads_call(GoogleAdsSaveParams, lambda ads, request: ads.save(request.login_customer_id))(rid, params)


@method("connectors.google_ads.verify")
@_profile_scoped
def _(rid, params):
    from tui_gateway.contracts.common import ProfileParams
    return _google_ads_call(ProfileParams, lambda ads, _request: ads.verify())(rid, params)


def register(server):
    bind_module(globals(), server, skip=("_",))
    server._LONG_HANDLERS = server._LONG_HANDLERS | _registry.names()
