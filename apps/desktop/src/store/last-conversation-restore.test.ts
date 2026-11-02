import { beforeEach, describe, expect, it, vi } from 'vitest'

import type { LastConversation } from './last-conversation'
import {
  type BotChatRestorer,
  type BotChatRestoreResult,
  claimsBootRestore,
  restoreLastConversation,
  type RestorePorts
} from './last-conversation-restore'

const botPointer: LastConversation = {
  connectionId: 'hermes-tsnanh-dev',
  kind: 'bot-chat',
  profile: 'chief',
  updatedAt: 1
}

const opened = (connectionId: string, profile: string): BotChatRestoreResult => ({
  connectionId,
  profile,
  status: 'opened'
})

function harness({
  pointer: initial = botPointer,
  ...over
}: Partial<Omit<RestorePorts, 'pointer'>> & { pointer?: LastConversation | null } = {}) {
  let pointer: LastConversation | null = initial
  const clock = { now: 0 }

  const restorer = vi.fn<BotChatRestorer>(async () => opened('pi', 'chief'))
  const clear = vi.fn(() => void (pointer = null))

  const ports: RestorePorts = {
    clear,
    connectionIds: () => new Set(['local', 'pi']),
    isCurrent: () => true,
    now: () => clock.now,
    pointer: () => pointer,
    pollMs: 1_000,
    registerGraceMs: 5_000,
    registryComplete: () => true,
    remember: next => {
      pointer = { ...next, updatedAt: clock.now } as LastConversation
    },
    restorer: () => restorer,
    sleep: async ms => void (clock.now += ms),
    timeoutMs: 10_000,
    ...over
  }

  return { clear, clock, pointer: () => pointer, ports, restorer }
}

describe('restoreLastConversation', () => {
  beforeEach(() => {
    vi.spyOn(console, 'warn').mockImplementation(() => undefined)
  })

  it('opens the remembered Bot Chat on its own connection and profile', async () => {
    const h = harness({ pointer: { ...botPointer, connectionId: 'pi' } })

    await expect(restoreLastConversation(h.ports)).resolves.toBe('opened')
    expect(h.restorer).toHaveBeenCalledTimes(1)
    expect(h.restorer.mock.calls[0]![0]).toEqual({ connectionId: 'pi', kind: 'bot', profile: 'chief' })
  })

  it('falls back to the primary connection newest Bot Chat when the connection is gone, and replaces the pointer', async () => {
    const h = harness()

    h.restorer.mockResolvedValue(opened('pi', 'faker-kit'))

    await expect(restoreLastConversation(h.ports)).resolves.toBe('fallback-opened')
    expect(h.restorer).toHaveBeenCalledTimes(1)
    expect(h.restorer.mock.calls[0]![0]).toEqual({ kind: 'primary-most-recent' })
    expect(h.pointer()).toMatchObject({ connectionId: 'pi', kind: 'bot-chat', profile: 'faker-kit' })
  })

  it('shows home, clears the stale pointer and surfaces nothing when no fallback exists', async () => {
    const h = harness()

    h.restorer.mockResolvedValue({ status: 'missing' })

    await expect(restoreLastConversation(h.ports)).resolves.toBe('home')
    expect(h.pointer()).toBeNull()
    expect(console.warn).not.toHaveBeenCalled()
  })

  it('treats a bot that vanished from a live connection like a stale pointer', async () => {
    const h = harness({ pointer: { ...botPointer, connectionId: 'pi' } })

    h.restorer.mockResolvedValueOnce({ status: 'missing' }).mockResolvedValueOnce(opened('pi', 'default'))

    await expect(restoreLastConversation(h.ports)).resolves.toBe('fallback-opened')
    expect(h.restorer.mock.calls.map(([target]) => target.kind)).toEqual(['bot', 'primary-most-recent'])
  })

  it('waits for a connecting connection, then opens', async () => {
    const h = harness({ pointer: { ...botPointer, connectionId: 'pi' } })

    h.restorer
      .mockResolvedValueOnce({ status: 'pending' })
      .mockResolvedValueOnce({ status: 'pending' })
      .mockResolvedValueOnce(opened('pi', 'chief'))

    await expect(restoreLastConversation(h.ports)).resolves.toBe('opened')
    expect(h.restorer).toHaveBeenCalledTimes(3)
    expect(h.clock.now).toBe(2_000)
  })

  it('gives up at the bounded timeout, keeps the pointer for the next launch and stays quiet', async () => {
    const h = harness({ pointer: { ...botPointer, connectionId: 'pi' } })

    h.restorer.mockResolvedValue({ status: 'pending' })

    await expect(restoreLastConversation(h.ports)).resolves.toBe('timed-out')
    expect(h.clock.now).toBeLessThanOrEqual(11_000)
    expect(h.pointer()).toMatchObject({ connectionId: 'pi', profile: 'chief' })
    expect(h.clear).not.toHaveBeenCalled()
  })

  it('a transient failure keeps retrying and opens once the backend answers', async () => {
    const h = harness({ pointer: { ...botPointer, connectionId: 'pi' } })

    h.restorer.mockRejectedValueOnce(new Error('dial failed')).mockRejectedValueOnce(new Error('lookup failed'))

    await expect(restoreLastConversation(h.ports)).resolves.toBe('opened')
    expect(h.restorer).toHaveBeenCalledTimes(3)
    expect(h.pointer()).toMatchObject({ connectionId: 'pi', profile: 'chief' })
  })

  it('a failure that never recovers times out without clearing the pointer', async () => {
    const h = harness({ pointer: { ...botPointer, connectionId: 'pi' } })

    h.restorer.mockRejectedValue(new Error('dial failed'))

    await expect(restoreLastConversation(h.ports)).resolves.toBe('timed-out')
    expect(h.pointer()).toMatchObject({ connectionId: 'pi' })
    expect(h.clear).not.toHaveBeenCalled()
  })

  it('never replaces a Bot Chat pointer whose connection still exists with the fallback bot', async () => {
    const h = harness({ pointer: { ...botPointer, connectionId: 'pi' } })

    h.restorer.mockResolvedValueOnce({ status: 'missing' }).mockResolvedValueOnce(opened('pi', 'faker-kit'))

    await expect(restoreLastConversation(h.ports)).resolves.toBe('fallback-opened')
    expect(h.pointer()).toMatchObject({ connectionId: 'pi', profile: 'chief' })
  })

  it('keeps a live connection pointer when no fallback exists', async () => {
    const h = harness({ pointer: { ...botPointer, connectionId: 'pi' } })

    h.restorer.mockResolvedValue({ status: 'missing' })

    await expect(restoreLastConversation(h.ports)).resolves.toBe('home')
    expect(h.pointer()).toMatchObject({ connectionId: 'pi', profile: 'chief' })
    expect(h.clear).not.toHaveBeenCalled()
  })

  it('a degraded registry that lacks the saved connection waits instead of declaring it gone', async () => {
    const h = harness({ connectionIds: () => new Set(['local']), registryComplete: () => false })

    await expect(restoreLastConversation(h.ports)).resolves.toBe('timed-out')
    expect(h.restorer).not.toHaveBeenCalled()
    expect(h.pointer()).toEqual(botPointer)
  })

  it('an incomplete registry that still names the saved connection restores normally', async () => {
    const h = harness({ pointer: { ...botPointer, connectionId: 'pi' }, registryComplete: () => false })

    await expect(restoreLastConversation(h.ports)).resolves.toBe('opened')
  })

  it('without a registered restorer it gives up after the grace period and keeps the pointer', async () => {
    const h = harness({ pointer: { ...botPointer, connectionId: 'pi' }, restorer: () => null })

    await expect(restoreLastConversation(h.ports)).resolves.toBe('timed-out')
    expect(h.clock.now).toBeGreaterThanOrEqual(5_000)
    expect(h.clock.now).toBeLessThan(7_000)
    expect(h.pointer()).toMatchObject({ connectionId: 'pi' })
    expect(h.clear).not.toHaveBeenCalled()
  })

  it('an explicit navigation before the first attempt wins', async () => {
    const h = harness({ isCurrent: () => false })

    await expect(restoreLastConversation(h.ports)).resolves.toBe('superseded')
    expect(h.restorer).not.toHaveBeenCalled()
    expect(h.pointer()).toEqual(botPointer)
  })

  it('an explicit navigation while waiting for the connection wins', async () => {
    let current = true
    const h = harness({ isCurrent: () => current, pointer: { ...botPointer, connectionId: 'pi' } })

    h.restorer.mockImplementation(async () => {
      current = false

      return { status: 'pending' }
    })

    await expect(restoreLastConversation(h.ports)).resolves.toBe('superseded')
    expect(h.restorer).toHaveBeenCalledTimes(1)
  })

  it('waits for the connection registry instead of guessing', async () => {
    let calls = 0

    const h = harness({
      connectionIds: () => (++calls < 3 ? null : new Set(['pi'])),
      pointer: { ...botPointer, connectionId: 'pi' }
    })

    await expect(restoreLastConversation(h.ports)).resolves.toBe('opened')
    expect(h.restorer.mock.calls[0]![0]).toMatchObject({ kind: 'bot' })
  })

  it('waits for the Bot Mode restorer to register', async () => {
    let calls = 0
    const h = harness({ pointer: { ...botPointer, connectionId: 'pi' } })
    const restorer = h.restorer

    h.ports.restorer = () => (++calls < 3 ? null : restorer)

    await expect(restoreLastConversation(h.ports)).resolves.toBe('opened')
  })

  it('a session pointer on a gone connection also falls back to the primary Bot Chat', async () => {
    const h = harness({
      pointer: { connectionId: 'hermes-tsnanh-dev', kind: 'session', profile: 'chief', sessionId: 's', updatedAt: 1 }
    })

    await expect(restoreLastConversation(h.ports)).resolves.toBe('fallback-opened')
    expect(h.restorer.mock.calls[0]![0]).toEqual({ kind: 'primary-most-recent' })
  })
})

describe('claimsBootRestore', () => {
  const ids = new Set(['local', 'pi'])

  const session = (connectionId: string): LastConversation => ({
    connectionId,
    kind: 'session',
    profile: 'default',
    sessionId: 's',
    updatedAt: 1
  })

  it('claims every Bot Chat pointer', () => {
    expect(claimsBootRestore(botPointer, null)).toBe(true)
    expect(claimsBootRestore(botPointer, ids)).toBe(true)
  })

  it('leaves session pointers on a live connection to the session restore', () => {
    expect(claimsBootRestore(session('pi'), ids)).toBe(false)
    expect(claimsBootRestore(session('pi'), null)).toBe(false)
  })

  it('claims a session pointer whose connection is gone', () => {
    expect(claimsBootRestore(session('gone'), ids)).toBe(true)
  })

  it('claims nothing without a pointer', () => {
    expect(claimsBootRestore(null, ids)).toBe(false)
  })
})
