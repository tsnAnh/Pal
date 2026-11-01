import { type ChatPersona, setHandlePersonas } from '@hermes/plugin-sdk'
import { afterEach, describe, expect, it, vi } from 'vitest'

import { startBotChatPersonas } from './bot-persona'
import { $lastRoster } from './data'

vi.mock('@hermes/plugin-sdk', async importOriginal => ({
  ...(await importOriginal<Record<string, unknown>>()),
  setHandlePersonas: vi.fn()
}))

vi.mock('./shared', () => ({ getPluginCtx: () => null, ID: 'hermes-bots' }))

let stop: (() => void) | null = null

afterEach(() => {
  stop?.()
  stop = null
  $lastRoster.set([])
  vi.mocked(setHandlePersonas).mockClear()
})

describe('bot chat voice labels', () => {
  it('gives every bot chat voice call and memo labels, with the duration in the ended card', () => {
    $lastRoster.set([{ name: 'scribe', title: 'Scribe' }])
    stop = startBotChatPersonas()

    const persona: ChatPersona | undefined = vi.mocked(setHandlePersonas).mock.calls.at(-1)![0].scribe
    const labels = persona?.voice?.()

    expect(labels?.startCall).toBe('Start voice chat')
    expect(labels?.hangUp).toBe('Hang up')
    expect(labels?.playMemo).toBe('Play voice memo')
    expect(labels?.callEnded('2:31')).toBe('Voice chat · 2:31')
  })
})
