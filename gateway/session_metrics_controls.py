from gateway.session_legacy_bridge import Verb, bridged


VERBS = {
    'shared_metrics.status': Verb('session:read'),
    'shared_metrics.set': Verb('session:control'),
}


def handlers(connection):
    return bridged(connection, VERBS)
