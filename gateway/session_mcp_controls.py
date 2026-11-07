from gateway.session_legacy_bridge import Verb, bridged


VERBS = {
    'mcp.catalog': Verb('session:read'),
    'mcp.servers.oauth.start': Verb('session:control'),
    'mcp.servers.oauth.poll': Verb('session:control'),
    'mcp.servers.oauth.cancel': Verb('session:control'),
}


def handlers(connection):
    return bridged(connection, VERBS)
