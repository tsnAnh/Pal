from gateway.session_legacy_bridge import Verb, bridged


VERBS = {
    'account.subscriptions': Verb('session:read'),
    'auth.revoke_self': Verb('session:control'),
}


def handlers(connection):
    return bridged(connection, VERBS)
