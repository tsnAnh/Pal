import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type * as CanonicalChat from './canonical-chat'
import type { RosterRow } from './types'

const { openBotCanonicalChat, prepareBotSource } = vi.hoisted(() => ({
  openBotCanonicalChat: vi.fn(),
  prepareBotSource: vi.fn()
}))

vi.mock('./canonical-chat', async () => ({
  CANONICAL_CHAT_TITLE: 'Bot Chat',
  ensureBotMetadata: vi.fn(async () => ({})),
  isStaleBotChatTile: (await vi.importActual<typeof CanonicalChat>('./canonical-chat')).isStaleBotChatTile,
  notifyBotOpenFailure: vi.fn(),
  openBotCanonicalChat,
  prepareBotSource,
  PROFILE_SESSION_LIST_LIMIT: 200
}))

const { host } = await import('@hermes/plugin-sdk')
const { openRosterBot } = await import('./roster-actions')

const bot = {
  canonical_session: { id: 'bot-chat', resolved_id: 'bot-chat-tip' },
  connectionId: 'pi',
  name: 'chief',
  sourceScoped: true
} as RosterRow

let remember: ReturnType<typeof vi.fn>

beforeEach(() => {
  vi.clearAllMocks()
  prepareBotSource.mockResolvedValue(undefined)
  openBotCanonicalChat.mockResolvedValue({ openedId: 'tip', registryId: 'reg' })
  remember = vi.fn()
  host.sessions.rememberBotChat = remember as never
})

afterEach(() => {
  // @ts-expect-error — restore the harness default (no focus verb).
  delete host.focusOpenWorkspaceSession
})

describe('openRosterBot records the reopen pointer', () => {
  it('after a cold registry open', async () => {
    await expect(openRosterBot(bot)).resolves.toBe(true)

    expect(remember).toHaveBeenCalledTimes(1)
    expect(remember).toHaveBeenCalledWith({ connectionId: 'pi', profile: 'chief' })
  })

  it('after fronting a Bot Chat tab that is already open', async () => {
    host.focusOpenWorkspaceSession = vi.fn(() => 'bot-chat-tip') as never

    await expect(openRosterBot(bot)).resolves.toBe(true)

    expect(remember).toHaveBeenCalledWith({ connectionId: 'pi', profile: 'chief' })
  })

  it('never carries a session id', async () => {
    await openRosterBot(bot)

    expect(JSON.stringify(remember.mock.calls)).not.toMatch(/bot-chat|tip|reg/)
  })

  it('not when the open failed', async () => {
    openBotCanonicalChat.mockRejectedValueOnce(new Error('gateway away'))

    await expect(openRosterBot(bot)).resolves.toBe(false)

    expect(remember).not.toHaveBeenCalled()
  })

  it('not when the source could not be reached', async () => {
    prepareBotSource.mockRejectedValueOnce(new Error('ssh down'))

    await expect(openRosterBot(bot)).resolves.toBe(false)

    expect(remember).not.toHaveBeenCalled()
  })
})
