from gateway.session_legacy_bridge import Verb, bridged


VERBS = {
    'capabilities.status': Verb('session:read'),
    'messaging.slack.status': Verb('session:read'),
    'messaging.slack.manifest': Verb('session:read'),
    'messaging.slack.connect': Verb('session:control'),
    'messaging.slack.disconnect': Verb('session:control'),
    'messaging.telegram.status': Verb('session:read'),
    'messaging.telegram.connect': Verb('session:control'),
    'messaging.telegram.disconnect': Verb('session:control'),
    'bot_mode.about_you.get': Verb('session:read'),
    'bot_mode.about_you.set': Verb('session:control'),
    'memory.import': Verb('session:control'),
}


def handlers(connection):
    return bridged(connection, VERBS)
