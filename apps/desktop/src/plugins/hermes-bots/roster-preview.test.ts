import { describe, expect, it } from 'vitest'

import { rosterPreview } from './roster-preview'
import type { RosterRow } from './types'

const row = (patch: Partial<RosterRow>): RosterRow => ({ name: 'alpha', ...patch })

describe('rosterPreview', () => {
  it('prefers the canonical Bot Chat preview over the latest session', () => {
    const bot = row({
      canonical_session: { id: 'c', preview: 'canonical words' } as RosterRow['canonical_session'],
      last_session: { id: 'l', preview: 'latest words' } as RosterRow['last_session']
    })

    expect(rosterPreview(bot, undefined).text).toBe('canonical words')
  })

  it('falls back to the latest session when the canonical chat has no preview', () => {
    const bot = row({
      canonical_session: { id: 'c', preview: '  ' } as RosterRow['canonical_session'],
      last_session: { id: 'l', preview: 'latest words' } as RosterRow['last_session']
    })

    expect(rosterPreview(bot, undefined).text).toBe('latest words')
  })

  it('falls back to the bot job, then to nothing', () => {
    expect(rosterPreview(row({ description: 'Triages the inbox' }), undefined).text).toBe('Triages the inbox')
    expect(rosterPreview(row({}), { description: 'From meta' }).text).toBe('From meta')
    expect(rosterPreview(row({}), undefined).text).toBe('')
  })

  it('collapses markdown and line breaks to one line', () => {
    const bot = row({
      last_session: { id: 'l', preview: '**Done**\n\n- shipped `it`\n  [link](https://x.y)' } as RosterRow['last_session']
    })

    expect(rosterPreview(bot, undefined).text).toBe('Done - shipped it link')
  })

  it('never shows the job when a chat preview exists', () => {
    const bot = row({
      description: 'Job text',
      last_session: { id: 'l', preview: 'hello' } as RosterRow['last_session']
    })

    expect(rosterPreview(bot, undefined)).toEqual({ fromBot: null, text: 'hello' })
  })
})
