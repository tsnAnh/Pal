import { describe, expect, it } from 'vitest'

import { deriveCards } from '../derive'
import type { BundledEntryInput, HostedConnectorInput, LocalServerInput } from '../types'

import { appStatus, buildAppsCatalog, CURATED_APPS, filterApps } from './catalog'

const hosted = (slug: string, overrides: Partial<HostedConnectorInput> = {}): HostedConnectorInput => ({
  connected: false,
  enabled: true,
  inCatalog: true,
  slug,
  ...overrides
})

const connectedHosted = (slug: string, connectionStatus: string, orgLocked = false): HostedConnectorInput =>
  hosted(slug, { connected: true, connectionStatus, orgLocked })

const bundled = (name: string, overrides: Partial<BundledEntryInput> = {}): BundledEntryInput => ({
  authType: 'oauth',
  name,
  needsEnv: false,
  ...overrides
})

const server = (name: string, overrides: Partial<LocalServerInput> = {}): LocalServerInput => ({
  enabled: true,
  inCatalog: true,
  name,
  status: 'ok',
  target: 'https://example.test/mcp',
  ...overrides
})

const build = (
  input: { bundled?: BundledEntryInput[]; hosted?: HostedConnectorInput[]; local?: LocalServerInput[] },
  phase: 'failed' | 'loading' | 'ready' | 'signedOut' = 'ready',
  catalogReady = true
) =>
  buildAppsCatalog({
    cards: deriveCards({ bundled: input.bundled, hosted: input.hosted ?? [], local: input.local ?? [] }),
    catalogReady,
    phase
  })

const byId = (entries: ReturnType<typeof build>['curated'], id: string) => entries.find(entry => entry.id === id)

describe('Connect apps catalog listing', () => {
  it('leads with the six curated apps in their fixed order whatever order the catalog arrives in', () => {
    const { curated } = build({
      hosted: ['slack', 'zapier', 'notion', 'googledrive', 'gmail', 'googlecalendar'].map(slug => hosted(slug))
    })

    expect(curated.map(entry => entry.id)).toEqual(CURATED_APPS.map(app => app.id))
    expect(curated.map(entry => entry.name)).toEqual([
      'Gmail',
      'Google Calendar',
      'Google Drive',
      'Slack',
      'Notion',
      '1Password'
    ])
  })

  it('lists everything else after the curated row by name, without repeating a curated app', () => {
    const { curated, others } = build({
      bundled: [bundled('linear'), bundled('asana')],
      hosted: [hosted('gmail'), hosted('zapier')]
    })

    expect(others.map(entry => entry.id)).toEqual(['asana', 'linear', 'zapier'])
    expect(curated.some(entry => others.some(other => other.id === entry.id))).toBe(false)
  })

  it('keeps plugin servers and servers the user wrote themselves out of the catalog', () => {
    const { others } = build({
      hosted: [hosted('zapier')],
      local: [server('my-own-server', { inCatalog: false }), server('plugin__tool', { plugin: 'a-plugin' })]
    })

    expect(others.map(entry => entry.id)).toEqual(['zapier'])
  })

  it('merges the hosted and bundled ways of one app into a single Notion entry', () => {
    const { curated } = build({
      bundled: [bundled('notion', { connectorSlug: 'notion' })],
      hosted: [hosted('notion')]
    })

    const notion = byId(curated, 'notion')

    expect(notion?.availability).toBe('available')
    expect(notion?.card?.ways.hosted).not.toBeNull()
    expect(notion?.card?.ways.local?.entryName).toBe('notion')
  })

  it('finds a curated app that only exists as a bundled MCP entry', () => {
    const { curated } = build({ bundled: [bundled('notion')] })

    expect(byId(curated, 'notion')?.availability).toBe('available')
    expect(byId(curated, 'notion')?.action).toBe('connect')
  })
})

describe('Connect apps availability', () => {
  it('marks a curated app with no connector and no catalog entry as not available yet', () => {
    const { curated } = build({ hosted: [hosted('gmail')] })

    expect(byId(curated, '1password')).toMatchObject({ action: 'none', availability: 'comingSoon', card: null })
    expect(byId(curated, 'gmail')?.availability).toBe('available')
  })

  it.each(['failed', 'loading', 'signedOut'] as const)(
    'does not claim an app is unavailable while the hosted catalog is %s',
    phase => {
      expect(byId(build({}, phase).curated, 'gmail')?.availability).toBe('unknown')
    }
  )

  it('does not claim an app is unavailable before the local catalog has loaded', () => {
    expect(byId(build({}, 'ready', false).curated, 'notion')?.availability).toBe('unknown')
  })

  it('still offers a curated app the local catalog has when the hosted side is signed out', () => {
    const { curated } = build({ bundled: [bundled('notion')] }, 'signedOut')

    expect(byId(curated, 'notion')?.availability).toBe('available')
  })
})

describe('Connect apps status', () => {
  const statusOf = (row: HostedConnectorInput) => byId(build({ hosted: [row] }).curated, row.slug) ?? null

  it('reads an active account as connected, with nothing to do', () => {
    expect(statusOf(connectedHosted('gmail', 'active'))).toMatchObject({ action: 'none', status: 'connected' })
  })

  it.each(['expired', 'revoked', 'inactive'])('reads a %s account as needing sign-in again', connection => {
    expect(statusOf(connectedHosted('gmail', connection))).toMatchObject({
      action: 'reconnect',
      status: 'needsSignIn'
    })
  })

  it('reads an app that was never connected as not connected, offering Connect', () => {
    expect(statusOf(hosted('gmail'))).toMatchObject({ action: 'connect', status: 'notConnected' })
  })

  it('offers Connect again, not Sign in again, for a connection that failed on its first try', () => {
    expect(statusOf(connectedHosted('gmail', 'failed'))).toMatchObject({ action: 'connect', status: 'notConnected' })
  })

  it('shows a sign-in in progress as pending, with a way to stop waiting', () => {
    expect(statusOf(connectedHosted('gmail', 'pending'))).toMatchObject({
      action: 'waiting',
      pending: true,
      status: 'notConnected'
    })
  })

  it('refuses Connect for an app the organisation turned off', () => {
    expect(statusOf(connectedHosted('gmail', 'active', true))).toMatchObject({ action: 'none', offByOrg: true })
  })

  it('reads a local server that lost its sign-in as needing sign-in again', () => {
    const { curated } = build({ local: [server('notion', { canAuthenticate: true, status: 'needs-auth' })] })

    expect(byId(curated, 'notion')).toMatchObject({ action: 'reconnect', status: 'needsSignIn' })
  })

  it('reads a local server that fails for another reason as not connected', () => {
    const card = build({ local: [server('notion', { status: 'error' })] }).curated[4].card

    expect(card && appStatus(card)).toBe('notConnected')
  })

  it('sends a bundled app that needs credentials to setup instead of asking for them here', () => {
    const { others } = build({ bundled: [bundled('algolia', { authType: 'apiKey', needsEnv: true })] })

    expect(others[0]).toMatchObject({ action: 'setup', status: 'notConnected' })
  })
})

describe('Connect apps search', () => {
  const entries = build({
    hosted: [
      hosted('gmail', { description: 'Mail' }),
      hosted('zapier', { description: 'Automations' }),
      hosted('linear', { description: 'Issue tracking' })
    ]
  })

  it('returns everything for an empty query', () => {
    expect(filterApps(entries.others, '  ')).toHaveLength(entries.others.length)
  })

  it('matches name and description without caring about case', () => {
    expect(filterApps(entries.others, 'ZAP').map(entry => entry.id)).toEqual(['zapier'])
    expect(filterApps(entries.others, 'issue').map(entry => entry.id)).toEqual(['linear'])
  })

  it('returns nothing for a query nothing matches', () => {
    expect(filterApps(entries.others, 'nothing-here')).toEqual([])
  })
})
