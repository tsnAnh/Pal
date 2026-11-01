import { beforeEach, describe, expect, it, vi } from 'vitest'

const requestForBot = vi.fn()
const notifyError = vi.fn()

vi.mock('./routing', () => ({
  requestForBot: (...args: unknown[]) => requestForBot(...args),
  resolveBotConnectionRoute: () => ({ route: { profile: 'scribe', targetProfile: 'scribe' } })
}))

vi.mock('@hermes/plugin-sdk', () => ({
  Checkbox: () => null,
  host: { notifyError: (...args: unknown[]) => notifyError(...args) }
}))

vi.mock('./data', () => ({ botSelectionKey: (bot: { name: string }) => bot.name }))

vi.mock('./i18n', () => ({
  botsText: () => ({ bot: { sendPolicySaveFailed: 'Could not save the send setting' } }),
  useBots: () => ({ bot: {} })
}))

import { applySendPolicy } from './bot-send-policy'
import type { RosterRow } from './types'

const bot = { name: 'scribe' } as RosterRow

beforeEach(() => {
  requestForBot.mockReset()
  notifyError.mockReset()
})

describe('applySendPolicy', () => {
  it('writes nothing until the owner changed the switch', async () => {
    expect(await applySendPolicy(bot, { ask: true, dirty: false, loaded: true })).toBe(true)
    expect(await applySendPolicy(bot, { ask: false, dirty: true, loaded: false })).toBe(true)
    expect(requestForBot).not.toHaveBeenCalled()
  })

  it('writes "Send without asking" to the bot profile config', async () => {
    requestForBot.mockResolvedValue({})

    expect(await applySendPolicy(bot, { ask: false, dirty: true, loaded: true })).toBe(true)
    expect(requestForBot).toHaveBeenCalledWith(bot, 'config.set', {
      key: 'bot_mode.drafts',
      profile: 'scribe',
      value: 'false'
    })
  })

  it('turns drafts back on', async () => {
    requestForBot.mockResolvedValue({})
    await applySendPolicy(bot, { ask: true, dirty: true, loaded: true })

    expect(requestForBot).toHaveBeenCalledWith(bot, 'config.set', expect.objectContaining({ value: 'true' }))
  })

  it('reports a failed write instead of pretending it saved', async () => {
    requestForBot.mockRejectedValue(new Error('boom'))

    expect(await applySendPolicy(bot, { ask: false, dirty: true, loaded: true })).toBe(false)
    expect(notifyError).toHaveBeenCalledWith(expect.any(Error), 'Could not save the send setting')
  })
})
