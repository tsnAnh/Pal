from gateway.session_legacy_bridge import Verb, bridged


VERBS = {
    'display.status': Verb('session:read'),
    'display.thumbnail': Verb('session:read'),
    'display.start': Verb('session:control'),
    'display.stop': Verb('session:control'),
    'display.reset': Verb('session:control'),
    'display.observe': Verb('session:control'),
    'display.lease.acquire': Verb('session:control'),
    'display.lease.release': Verb('session:control'),
    'display.lease.resolve': Verb('session:control'),
}


def handlers(connection):
    return bridged(connection, VERBS)
