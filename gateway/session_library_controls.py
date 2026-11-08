from gateway.session_legacy_bridge import Verb, bridged


VERBS = {
    'library.list': Verb('session:read'),
    'library.asset': Verb('session:read'),
}


def handlers(connection):
    return bridged(connection, VERBS)
