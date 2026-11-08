from gateway.session_legacy_bridge import Verb, action_scope, bridged


VERBS = {
    'cron.manage': Verb(action_scope({'list', 'history', 'schedule_preview'}, {'add', 'remove', 'pause', 'resume', 'run'})),
}


def handlers(connection):
    return bridged(connection, VERBS)
