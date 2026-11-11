from gateway.session_legacy_bridge import Verb, bridged
from hermes_state_runtime import RuntimeStoreError


def catalog_preset_only(params):
    if params.get('config') is not None or not isinstance(params.get('preset'), str) or not params['preset'].strip():
        raise RuntimeStoreError('invalid_params', field='config',
                                detail='only catalog presets can be added over the socket')


def no_endpoint_edit(params):
    if params.get('config') is not None:
        raise RuntimeStoreError('invalid_params', field='config',
                                detail='a server endpoint cannot be changed over the socket')


VERBS = {
    'mcp.catalog': Verb('session:read'),
    'mcp.servers.add': Verb('session:control', guard=catalog_preset_only),
    'mcp.servers.update': Verb('session:control', guard=no_endpoint_edit),
    'mcp.servers.remove': Verb('session:control'),
    'mcp.servers.set_api_key': Verb('session:control'),
    'mcp.servers.oauth.start': Verb('session:control'),
    'mcp.servers.oauth.poll': Verb('session:control'),
    'mcp.servers.oauth.cancel': Verb('session:control'),
    'mcp.servers.oauth.callback': Verb('session:control'),
}


def handlers(connection):
    return bridged(connection, VERBS)
