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
    'messaging.settings.get': Verb('session:read'),
    'messaging.settings.update': Verb('session:control'),
    'bot_mode.about_you.get': Verb('session:read'),
    'bot_mode.about_you.set': Verb('session:control'),
    'bot_mode.about_you.set_photo': Verb('session:control'),
    'bot_mode.about_you.photo': Verb('session:read'),
    'memory.import': Verb('session:control'),
    'chat.provider.list': Verb('session:read', owner_scoped=True),
    'chat.install.status': Verb('session:read', owner_scoped=True),
    'chat.spaces.list': Verb('session:read', owner_scoped=True),
    'chat.binding.list': Verb('session:read', owner_scoped=True),
    'chat.install.begin': Verb('session:control', owner_scoped=True),
    'chat.install.advance': Verb('session:control', owner_scoped=True),
    'chat.space.join': Verb('session:control', owner_scoped=True),
    'chat.install.revoke': Verb('session:control', owner_scoped=True),
    'chat.install.update_identity': Verb('session:control', owner_scoped=True),
    'chat.install.set_icon': Verb('session:control', owner_scoped=True),
    'chat.space.leave': Verb('session:control', owner_scoped=True),
    'chat.audience.get': Verb('session:read', owner_scoped=True),
    'chat.audience.set': Verb('session:control', owner_scoped=True),
    'chat.people.list': Verb('session:read', owner_scoped=True),
    'chat.report.get': Verb('session:read', owner_scoped=True),
    'chat.report.set': Verb('session:control', owner_scoped=True),
    'chat.desk.list': Verb('session:read', owner_scoped=True),
    'chat.desk.decide': Verb('session:control', owner_scoped=True),
    'diag.recent': Verb('session:read', owner_scoped=True),
    'diag.report': Verb('session:control', owner_scoped=True),
    'webapp.public_url.get': Verb('session:read', owner_scoped=True),
    'webapp.public_url.set': Verb('session:control', owner_scoped=True),
    'webapp.public_url.check': Verb('session:control', owner_scoped=True),
}


def handlers(connection):
    return bridged(connection, VERBS)
