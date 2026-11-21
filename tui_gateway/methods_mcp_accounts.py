from .method_ctx import HandlerRegistry, bind_module

_registry = HandlerRegistry()
method = _registry.method
_profile_scoped = _registry.profile_scoped


@method("mcp.servers.accounts.rename")
@_profile_scoped
def _(rid, params):
    from tui_gateway import mcp_account_rpc

    renamed, failure = mcp_account_rpc.rename(params)
    return _err(rid, *failure) if failure else _ok(rid, renamed)


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
