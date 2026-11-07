from gateway.session_legacy_bridge import Verb, action_scope, bridged


VERBS = {
    'skills.manage': Verb(action_scope({'list', 'search', 'browse', 'inspect'}, set())),
}


def handlers(connection):
    return bridged(connection, VERBS)
