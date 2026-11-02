import { beforeEach, describe, expect, it } from 'vitest'

import { $workspaceMode, setWorkspaceScope } from '@/components/pane-shell/workspace-scope'

import { $lastConversation, clearLastConversation } from './last-conversation'
import { recordSessionConversation } from './last-conversation-restore'
import {
  _resetSessionOwnerHintsForTests,
  forgetSessionOwnerHintsForUnknownConnections,
  getSessionOwnerHints,
  setSessionOwnerHint
} from './session'

describe('recordSessionConversation', () => {
  beforeEach(() => {
    window.localStorage.clear()
    clearLastConversation()
    setWorkspaceScope('sessions', null, null)
  })

  it('remembers the routed session with its connection and profile', () => {
    recordSessionConversation({ connectionId: 'pi', profile: 'default', sessionId: 's1' })

    expect($lastConversation.get()).toMatchObject({
      connectionId: 'pi',
      kind: 'session',
      profile: 'default',
      sessionId: 's1'
    })
  })

  it('does nothing without a connection identity', () => {
    recordSessionConversation({ connectionId: null, profile: 'default', sessionId: 's1' })

    expect($lastConversation.get()).toBeNull()
  })

  it('never replaces a Bot Chat pointer with the session the Bots workspace shows', () => {
    setWorkspaceScope('bots', 'bot:pi::chief', null)
    expect($workspaceMode.get()).toBe('bots')
    $lastConversation.set({ connectionId: 'pi', kind: 'bot-chat', profile: 'chief', updatedAt: 1 })

    recordSessionConversation({ connectionId: 'pi', profile: 'chief', sessionId: 'canonical-id' })

    expect($lastConversation.get()).toEqual({ connectionId: 'pi', kind: 'bot-chat', profile: 'chief', updatedAt: 1 })
  })
})

describe('stale session owner hints', () => {
  beforeEach(() => {
    window.localStorage.clear()
    _resetSessionOwnerHintsForTests({ storage: true })
  })

  it('drops hints for connections the registry no longer has', () => {
    setSessionOwnerHint('20261012_141020_f8fdb1', { connectionId: 'hermes-tsnanh-dev', profile: 'chief' })
    setSessionOwnerHint('kept', { connectionId: 'pi', profile: 'chief' })
    setSessionOwnerHint('legacy-local', { connectionId: 'local', profile: 'default' })

    forgetSessionOwnerHintsForUnknownConnections(new Set(['pi']))

    expect(getSessionOwnerHints('20261012_141020_f8fdb1')).toEqual([])
    expect(getSessionOwnerHints('kept')).toHaveLength(1)
    expect(getSessionOwnerHints('legacy-local')).toHaveLength(1)
  })

  it('keeps every hint when the registry is empty rather than treating it as authoritative', () => {
    setSessionOwnerHint('s', { connectionId: 'pi', profile: 'chief' })

    forgetSessionOwnerHintsForUnknownConnections(new Set())

    expect(getSessionOwnerHints('s')).toHaveLength(1)
  })
})
