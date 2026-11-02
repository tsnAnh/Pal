import { beforeEach, describe, expect, it, vi } from 'vitest'

const KEY = 'hermes.desktop.lastConversation.v1'

async function freshStore() {
  vi.resetModules()

  return import('./last-conversation')
}

describe('last conversation pointer', () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  it('persists a Bot Chat as bot identity and a relaunch reads it back', async () => {
    const first = await freshStore()

    first.rememberLastConversation({ connectionId: 'pi', kind: 'bot-chat', profile: 'chief' }, 1_000)

    const relaunched = await freshStore()

    expect(relaunched.$lastConversation.get()).toEqual({
      connectionId: 'pi',
      kind: 'bot-chat',
      profile: 'chief',
      updatedAt: 1_000
    })
  })

  it('never stores a session id for a Bot Chat', async () => {
    const store = await freshStore()

    store.rememberLastConversation(
      { connectionId: 'pi', kind: 'bot-chat', profile: 'chief', sessionId: 'old-canonical' } as never,
      1_000
    )

    expect(window.localStorage.getItem(KEY)).not.toContain('old-canonical')
  })

  it('persists a normal session with its owner scope', async () => {
    const store = await freshStore()

    store.rememberLastConversation({ connectionId: 'local', kind: 'session', profile: 'default', sessionId: 's1' }, 5)

    expect((await freshStore()).$lastConversation.get()).toEqual({
      connectionId: 'local',
      kind: 'session',
      profile: 'default',
      sessionId: 's1',
      updatedAt: 5
    })
  })

  it('keeps updatedAt when the same conversation is remembered again', async () => {
    const store = await freshStore()
    const target = { connectionId: 'pi', kind: 'bot-chat', profile: 'chief' } as const

    store.rememberLastConversation(target, 10)
    store.rememberLastConversation(target, 99)

    expect(store.$lastConversation.get()?.updatedAt).toBe(10)
  })

  it('moves to the newest conversation when the owner switches', async () => {
    const store = await freshStore()

    store.rememberLastConversation({ connectionId: 'pi', kind: 'bot-chat', profile: 'chief' }, 10)
    store.rememberLastConversation({ connectionId: 'pi', kind: 'bot-chat', profile: 'faker-kit' }, 20)

    expect(store.$lastConversation.get()).toMatchObject({ profile: 'faker-kit', updatedAt: 20 })
  })

  it.each([
    ['not json', '{'],
    ['wrong shape', JSON.stringify({ kind: 'bot-chat' })],
    ['unknown kind', JSON.stringify({ connectionId: 'a', kind: 'x', profile: 'p', updatedAt: 1 })],
    ['session without id', JSON.stringify({ connectionId: 'a', kind: 'session', profile: 'p', updatedAt: 1 })],
    ['blank connection', JSON.stringify({ connectionId: ' ', kind: 'bot-chat', profile: 'p', updatedAt: 1 })]
  ])('ignores a malformed stored pointer (%s)', async (_label, raw) => {
    window.localStorage.setItem(KEY, raw)

    expect((await freshStore()).$lastConversation.get()).toBeNull()
  })

  it('clearing removes the persisted pointer', async () => {
    const store = await freshStore()

    store.rememberLastConversation({ connectionId: 'pi', kind: 'bot-chat', profile: 'chief' }, 1)
    store.clearLastConversation()

    expect(window.localStorage.getItem(KEY)).toBeNull()
    expect((await freshStore()).$lastConversation.get()).toBeNull()
  })
})
