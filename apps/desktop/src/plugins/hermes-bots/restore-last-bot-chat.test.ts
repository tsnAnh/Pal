import { beforeEach, describe, expect, it, vi } from 'vitest'

import type * as Data from './data'
import type { RosterRow } from './types'

const { cachedUnionRoster, openBotCanonicalChat, prepareBotSource, primeRoster } = vi.hoisted(() => ({
  cachedUnionRoster: vi.fn(),
  openBotCanonicalChat: vi.fn(),
  prepareBotSource: vi.fn(),
  primeRoster: vi.fn()
}))

vi.mock('./canonical-chat', () => ({
  CANONICAL_CHAT_TITLE: 'Bot Chat',
  openBotCanonicalChat,
  prepareBotSource
}))

vi.mock('./data', async importOriginal => ({
  ...(await importOriginal<typeof Data>()),
  cachedUnionRoster,
  primeRoster
}))

const { host } = await import('@hermes/plugin-sdk')
const { $selectedRosterKey } = await import('./bot-state')
const { bumpBotOpenGeneration } = await import('./shared')
const { botChatIdentity, restoreBotChat } = await import('./restore-last-bot-chat')

const row = (name: string, over: Partial<RosterRow> = {}): RosterRow => ({
  canonical_session: { id: `${name}-chat`, last_active: 100, resolved_id: `${name}-chat-tip` },
  connectionId: 'pi',
  name,
  sourceReachable: true,
  sourceScoped: true,
  ...over
})

function roster(profiles: RosterRow[], sources = [{ connectionId: 'pi', reachable: true }]) {
  cachedUnionRoster.mockReturnValue({ primaryConnectionId: 'pi', profiles, sources })
}

const always = () => true

beforeEach(() => {
  vi.clearAllMocks()
  primeRoster.mockResolvedValue(undefined)
  prepareBotSource.mockResolvedValue(undefined)
  openBotCanonicalChat.mockResolvedValue({ openedId: 'tip', registryId: 'reg' })
  $selectedRosterKey.set('')
  vi.spyOn(host, 'notifyError').mockImplementation(() => '')
})

describe('restoreBotChat, remembered bot', () => {
  it('resolves the CURRENT canonical chat by name, never a stored session id', async () => {
    roster([row('chief', { canonical_session: { id: 'brand-new-canonical', resolved_id: 'brand-new-tip' } })])

    const result = await restoreBotChat({ connectionId: 'pi', kind: 'bot', profile: 'chief' }, always)

    expect(result).toEqual({ connectionId: 'pi', profile: 'chief', status: 'opened' })
    expect(openBotCanonicalChat).toHaveBeenCalledTimes(1)

    const [bot, options] = openBotCanonicalChat.mock.calls[0]!

    expect(bot).toMatchObject({ connectionId: 'pi', name: 'chief' })
    expect(options).toMatchObject({ createIfMissing: false, intent: 'in-place' })
    expect(JSON.stringify(botChatIdentity(bot))).not.toMatch(/canonical|tip/)
  })

  it('selects the bot row the way a click does', async () => {
    roster([row('chief')])

    await restoreBotChat({ connectionId: 'pi', kind: 'bot', profile: 'chief' }, always)

    expect($selectedRosterKey.get()).toBe('pi::chief')
  })

  it('is pending while its connection is still dialing', async () => {
    roster([], [{ connectionId: 'pi', reachable: false }])

    await expect(restoreBotChat({ connectionId: 'pi', kind: 'bot', profile: 'chief' }, always)).resolves.toEqual({
      status: 'pending'
    })
    expect(openBotCanonicalChat).not.toHaveBeenCalled()
  })

  it('is pending while an unreachable source only offers a retained twin', async () => {
    roster([row('chief', { retained: true, sourceReachable: false })], [{ connectionId: 'pi', reachable: false }])

    await expect(restoreBotChat({ connectionId: 'pi', kind: 'bot', profile: 'chief' }, always)).resolves.toEqual({
      status: 'pending'
    })
  })

  it('is missing when a reachable connection no longer has the bot', async () => {
    roster([row('default')])

    await expect(restoreBotChat({ connectionId: 'pi', kind: 'bot', profile: 'chief' }, always)).resolves.toEqual({
      status: 'missing'
    })
  })

  it('never mints a chat: no canonical chat means missing, with no toast', async () => {
    roster([row('chief')])
    openBotCanonicalChat.mockResolvedValue(null)

    await expect(restoreBotChat({ connectionId: 'pi', kind: 'bot', profile: 'chief' }, always)).resolves.toEqual({
      status: 'missing'
    })
    expect(host.notifyError).not.toHaveBeenCalled()
  })

  it('a failed open is silent', async () => {
    roster([row('chief')])
    openBotCanonicalChat.mockRejectedValue(new Error('gateway away'))

    await expect(restoreBotChat({ connectionId: 'pi', kind: 'bot', profile: 'chief' }, always)).resolves.toEqual({
      status: 'failed'
    })
    expect(host.notifyError).not.toHaveBeenCalled()
  })

  it('a failed source activation is silent too', async () => {
    roster([row('chief')])
    prepareBotSource.mockRejectedValue(new Error('ssh down'))

    await expect(restoreBotChat({ connectionId: 'pi', kind: 'bot', profile: 'chief' }, always)).resolves.toEqual({
      status: 'failed'
    })
    expect(openBotCanonicalChat).not.toHaveBeenCalled()
    expect(host.notifyError).not.toHaveBeenCalled()
  })

  it('yields to a navigation the owner made before the open', async () => {
    roster([row('chief')])

    await expect(
      restoreBotChat({ connectionId: 'pi', kind: 'bot', profile: 'chief' }, () => false)
    ).resolves.toEqual({ status: 'superseded' })
    expect(openBotCanonicalChat).not.toHaveBeenCalled()
  })

  it('yields to a roster click that lands while the source is being prepared', async () => {
    roster([row('chief')])
    prepareBotSource.mockImplementation(async () => void bumpBotOpenGeneration())

    await expect(restoreBotChat({ connectionId: 'pi', kind: 'bot', profile: 'chief' }, always)).resolves.toEqual({
      status: 'superseded'
    })
    expect(openBotCanonicalChat).not.toHaveBeenCalled()
  })
})

describe('restoreBotChat, primary fallback', () => {
  it('opens the most recently active Bot Chat on the primary connection', async () => {
    roster([
      row('default', { canonical_session: { id: 'a', last_active: 10 } }),
      row('faker-kit', { canonical_session: { id: 'b', last_active: 300 } }),
      row('chief', { canonical_session: { id: 'c', last_active: 200 } }),
      row('elsewhere', { canonical_session: { id: 'd', last_active: 999 }, connectionId: 'vps' })
    ])

    const result = await restoreBotChat({ kind: 'primary-most-recent' }, always)

    expect(result).toEqual({ connectionId: 'pi', profile: 'faker-kit', status: 'opened' })
    expect(openBotCanonicalChat.mock.calls[0]![0]).toMatchObject({ name: 'faker-kit' })
  })

  it('skips bots with no Bot Chat yet', async () => {
    roster([row('fresh', { canonical_session: null }), row('chief', { canonical_session: { id: 'c', last_active: 1 } })])

    await expect(restoreBotChat({ kind: 'primary-most-recent' }, always)).resolves.toMatchObject({
      profile: 'chief',
      status: 'opened'
    })
  })

  it('is missing when the primary connection has no Bot Chat', async () => {
    roster([row('fresh', { canonical_session: null })])

    await expect(restoreBotChat({ kind: 'primary-most-recent' }, always)).resolves.toEqual({ status: 'missing' })
  })

  it('is pending while the primary connection is unreachable', async () => {
    roster([], [{ connectionId: 'pi', reachable: false }])

    await expect(restoreBotChat({ kind: 'primary-most-recent' }, always)).resolves.toEqual({ status: 'pending' })
  })

  it('is pending before the first roster arrives', async () => {
    cachedUnionRoster.mockReturnValue(null)

    await expect(restoreBotChat({ kind: 'primary-most-recent' }, always)).resolves.toEqual({ status: 'pending' })
  })
})
