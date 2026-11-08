from gateway.session_legacy_bridge import Verb, bridged


VERBS = {
    'vault.list': Verb('session:read'),
    'vault.sources': Verb('session:read'),
    'vault.add': Verb('session:control'),
    'vault.remove': Verb('session:control'),
    'vault.unlock': Verb('session:control'),
    'vault.lock': Verb('session:control'),
}


def handlers(connection):
    return bridged(connection, VERBS)
