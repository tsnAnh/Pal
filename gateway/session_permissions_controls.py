from gateway.session_legacy_bridge import Verb, bridged


VERBS = {
    'permissions.get': Verb('session:read'),
    'permissions.set_auto_review': Verb('session:control'),
    'permissions.rules.add': Verb('session:control'),
    'permissions.rules.remove': Verb('session:control'),
}


def handlers(connection):
    return bridged(connection, VERBS)
