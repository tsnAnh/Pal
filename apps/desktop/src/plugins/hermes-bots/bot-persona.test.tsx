import { type ChatPersona, setHandlePersonas } from '@hermes/plugin-sdk'
import { afterEach, describe, expect, it, vi } from 'vitest'

import { startBotChatPersonas } from './bot-persona'
import { $lastRoster } from './data'
import type { RosterRow } from './types'

vi.mock('@hermes/plugin-sdk', async importOriginal => ({
  ...(await importOriginal<Record<string, unknown>>()),
  setHandlePersonas: vi.fn()
}))

vi.mock('./shared', () => ({ getPluginCtx: () => null, ID: 'hermes-bots' }))

let stop: (() => void) | null = null

function handlePersonasFor(roster: RosterRow[]): Readonly<Record<string, ChatPersona>> {
  $lastRoster.set(roster)
  stop = startBotChatPersonas()

  return vi.mocked(setHandlePersonas).mock.calls.at(-1)![0]
}

afterEach(() => {
  stop?.()
  stop = null
  $lastRoster.set([])
  vi.mocked(setHandlePersonas).mockClear()
})

describe('bot chat handle personas', () => {
  it('lets a profile name beat another row that merely claims the same handle', () => {
    const personas = handlePersonasFor([
      { name: 'scribe', title: 'Real Scribe' },
      { name: 'other', handle: 'scribe', title: 'Imposter' }
    ])

    expect(personas.scribe?.name).toBe('Real Scribe')
    expect(personas.other?.name).toBe('Imposter')
  })

  it('keeps the primary profile on the hermes alias when another connection also has a default', () => {
    const personas = handlePersonasFor([
      { connectionId: 'local', name: 'default', title: 'Local Hermes' },
      { connectionId: 'laptop', handle: 'hermes-laptop', name: 'default', title: 'Laptop Hermes' }
    ])

    expect(personas.hermes?.name).toBe('Local Hermes')
    expect(personas['hermes-laptop']?.name).toBe('Laptop Hermes')
  })
})

describe('bot chat stop now', () => {
  it('gives every bot chat a localized Stop now label', () => {
    const personas = handlePersonasFor([{ name: 'scribe', title: 'Scribe' }])

    expect(personas.scribe?.stopNowLabel?.()).toBe('Stop now')
  })
})
