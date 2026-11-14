from gateway.session_legacy_bridge import Verb, bridged
from hermes_state_runtime import RuntimeStoreError


_URL_SERVER_KEYS = frozenset({'url', 'transport'})


def _refuse_device_transport(config, *, field='config'):
    if isinstance(config, dict) and config.get('transport') == 'device':
        raise RuntimeStoreError('invalid_params', field=field,
                                detail='a device server is created only by the device that offers it')


def _url_server_config(config, *, field='config'):
    _refuse_device_transport(config, field=field)
    if not isinstance(config, dict) or not isinstance(config.get('url'), str) or not config['url'].strip():
        raise RuntimeStoreError('invalid_params', field=field, detail='a url server needs a url')
    if set(config) - _URL_SERVER_KEYS:
        raise RuntimeStoreError('invalid_params', field=field,
                                detail='only a url and transport can be set over the socket')


def catalog_preset_only(params):
    config = params.get('config')
    if config is not None:
        _url_server_config(config)
        return
    if not isinstance(params.get('preset'), str) or not params['preset'].strip():
        raise RuntimeStoreError('invalid_params', field='config',
                                detail='only catalog presets or url servers can be added over the socket')


def url_endpoint_edit(params):
    config = params.get('config')
    _refuse_device_transport(config)
    if config is not None and (not isinstance(config, dict) or set(config) - _URL_SERVER_KEYS):
        raise RuntimeStoreError('invalid_params', field='config',
                                detail='only a url and transport can be changed over the socket')


VERBS = {
    'mcp.catalog': Verb('session:read'),
    'mcp.servers.add': Verb('session:control', guard=catalog_preset_only),
    'mcp.servers.update': Verb('session:control', guard=url_endpoint_edit),
    'mcp.servers.remove': Verb('session:control'),
    'mcp.servers.set_api_key': Verb('session:control'),
    'mcp.servers.oauth.start': Verb('session:control'),
    'mcp.servers.oauth.poll': Verb('session:control'),
    'mcp.servers.oauth.cancel': Verb('session:control'),
    'mcp.servers.oauth.callback': Verb('session:control'),
}


def handlers(connection):
    return bridged(connection, VERBS)
