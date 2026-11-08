from gateway.session_legacy_bridge import Verb, account_owned, bridged, serve

VERBS = {
    'connectors.list': Verb('session:read', guard=account_owned),
    'connectors.catalog': Verb('session:read'),
}

ACCOUNT_OWNED_VERBS = {
    'connectors.connect': Verb('session:control', guard=account_owned),
    'connectors.operation.status': Verb('session:read', guard=account_owned),
    'connectors.operation.wake': Verb('session:control', guard=account_owned),
    'connection.respond': Verb('session:control', guard=account_owned),
}


async def serve_account_owned(connection, method, params):
    return await serve(connection, method, ACCOUNT_OWNED_VERBS[method], None, params)


def handlers(connection):
    return bridged(connection, VERBS)
