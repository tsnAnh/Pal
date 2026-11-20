from gateway.session_legacy_bridge import Verb, account_owned, bridged

VERBS = {
    'connectors.list': Verb('session:read', guard=account_owned),
    'connectors.catalog': Verb('session:read'),
    'connectors.accounts': Verb('session:read'),
    'connectors.legacy': Verb('session:read', owner_scoped=True),
    'connectors.accounts.remove': Verb('session:control'),
}


def handlers(connection):
    return bridged(connection, VERBS)
