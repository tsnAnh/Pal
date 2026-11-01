import type * as HermesSdk from '@hermes/plugin-sdk'
import type { AppBot, AppEntry, ConnectorAppsView } from '@hermes/plugin-sdk'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { translateBots } from './i18n-test-helper'

const mocks = vi.hoisted(() => ({ view: null as unknown as ConnectorAppsView }))

vi.mock('@hermes/plugin-sdk', async importOriginal => {
  const original = await importOriginal<typeof HermesSdk>()

  return {
    ...original,
    useConnectorApps: () => mocks.view,
    usePluginI18n: () => translateBots
  }
})

const { $lastRoster } = await import('./data')
const { $connectApps, closeConnectApps, openConnectApps } = await import('./connect-apps')
const { ConnectAppsDialog } = await import('./connect-apps-dialog')

const entry = (id: string, name: string, overrides: Partial<AppEntry> = {}): AppEntry => ({
  action: 'connect',
  availability: 'available',
  // SAFETY: the dialog only checks that a card exists.
  card: {} as AppEntry['card'],
  curated: false,
  id,
  name,
  offByOrg: false,
  pending: false,
  status: 'notConnected',
  ...overrides
})

const CURATED = [
  entry('gmail', 'Gmail', { action: 'none', curated: true, status: 'connected' }),
  entry('googlecalendar', 'Google Calendar', { action: 'reconnect', curated: true, status: 'needsSignIn' }),
  entry('slack', 'Slack', { curated: true }),
  entry('1password', '1Password', { action: 'none', availability: 'comingSoon', card: null, curated: true })
]

const OTHERS = [entry('asana', 'Asana'), entry('linear', 'Linear')]

const WRITER: AppBot = { id: '::writer', label: 'writer', scope: 'writer' }

function makeView(overrides: Partial<ConnectorAppsView> = {}): ConnectorAppsView {
  return {
    access: vi.fn(() => 'off' as const),
    busyId: null,
    catalog: { curated: CURATED, others: OTHERS },
    connect: vi.fn(),
    failed: false,
    loading: false,
    openInSettings: vi.fn(),
    phase: 'ready',
    refetch: vi.fn(),
    setAccess: vi.fn(async () => null),
    signInBot: vi.fn(async () => {}),
    usedBy: vi.fn(() => []),
    ...overrides
  }
}

const rowFor = (id: string) => {
  const row = screen.getByRole('dialog').querySelector<HTMLElement>(`[data-app="${id}"]`)

  expect(row).not.toBeNull()

  return within(row as HTMLElement)
}

beforeEach(() => {
  mocks.view = makeView()
  $lastRoster.set([{ name: 'writer' }, { name: 'analyst' }])
  openConnectApps()
})

afterEach(() => {
  cleanup()
  closeConnectApps()
  $lastRoster.set([])
})

describe('Connect apps dialog', () => {
  it('lists the curated apps first, then the rest, each under its own heading', () => {
    render(<ConnectAppsDialog />)

    const names = [...screen.getByRole('dialog').querySelectorAll('[data-app]')].map(node =>
      node.getAttribute('data-app')
    )

    expect(names).toEqual(['gmail', 'googlecalendar', 'slack', '1password', 'asana', 'linear'])
    expect(screen.getByRole('heading', { name: 'Popular' })).toBeTruthy()
    expect(screen.getByRole('heading', { name: 'More apps' })).toBeTruthy()
  })

  it('says what state each app is in, in product words', () => {
    render(<ConnectAppsDialog />)

    expect(rowFor('gmail').getByText('Connected')).toBeTruthy()
    expect(rowFor('googlecalendar').getByText('Needs sign-in again')).toBeTruthy()
    expect(rowFor('slack').getByText('Not connected')).toBeTruthy()
    expect(rowFor('1password').getByText('Not available yet')).toBeTruthy()
  })

  it('offers no button for an app that is not available yet', () => {
    render(<ConnectAppsDialog />)

    expect(rowFor('1password').queryByRole('button')).toBeNull()
  })

  it('runs the connect flow from Connect, and Sign in again for an expired app', () => {
    render(<ConnectAppsDialog />)

    fireEvent.click(rowFor('slack').getByRole('button', { name: 'Connect' }))
    fireEvent.click(rowFor('googlecalendar').getByRole('button', { name: 'Sign in again' }))

    expect(vi.mocked(mocks.view.connect).mock.calls.map(([app]) => app.id)).toEqual(['slack', 'googlecalendar'])
  })

  it('leaves the dialog and opens the existing Connectors setup for an app that needs credentials', () => {
    mocks.view = makeView({
      catalog: { curated: [entry('slack', 'Slack', { action: 'setup', curated: true })], others: [] }
    })

    render(<ConnectAppsDialog />)
    fireEvent.click(screen.getByRole('button', { name: 'Set up…' }))

    expect(mocks.view.openInSettings).toHaveBeenCalledWith(expect.objectContaining({ id: 'slack' }))
    expect($connectApps.get().open).toBe(false)
  })

  it('lets a sign-in in progress be cancelled', () => {
    mocks.view = makeView({
      catalog: { curated: [entry('slack', 'Slack', { action: 'waiting', curated: true, pending: true })], others: [] }
    })

    render(<ConnectAppsDialog />)
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))

    expect(mocks.view.connect).toHaveBeenCalledOnce()
  })

  it('shows which bots use a connected app', () => {
    mocks.view = makeView({ usedBy: vi.fn(app => (app.id === 'gmail' ? [WRITER] : [])) })

    render(<ConnectAppsDialog />)

    expect(rowFor('gmail').getByText('Used by writer')).toBeTruthy()
  })

  it('filters every section by the search text', () => {
    render(<ConnectAppsDialog />)

    fireEvent.change(screen.getByLabelText('Search apps'), { target: { value: 'lin' } })

    expect(
      [...screen.getByRole('dialog').querySelectorAll('[data-app]')].map(node => node.getAttribute('data-app'))
    ).toEqual(['linear'])
    expect(screen.queryByRole('heading', { name: 'Popular' })).toBeNull()

    fireEvent.change(screen.getByLabelText('Search apps'), { target: { value: 'zzz' } })

    expect(screen.getByText('No apps match your search.')).toBeTruthy()
  })

  it('tells the owner when the hosted catalog could not load, with a way to retry', () => {
    mocks.view = makeView({ failed: true, phase: 'failed' })

    render(<ConnectAppsDialog />)
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }))

    expect(screen.getByText('Couldn’t load apps.')).toBeTruthy()
    expect(mocks.view.refetch).toHaveBeenCalledOnce()
  })

  it('asks the owner to sign in when the hosted side is signed out', () => {
    mocks.view = makeView({ phase: 'signedOut' })

    render(<ConnectAppsDialog />)

    expect(screen.getByText('Sign in to Hermes to connect apps.')).toBeTruthy()
  })
})

describe('Connect apps per-bot access', () => {
  const openBots = () => fireEvent.click(rowFor('gmail').getByRole('button', { name: 'Choose bots' }))

  it('shows the bot switches only for a connected app, after Choose bots', () => {
    render(<ConnectAppsDialog />)

    expect(rowFor('gmail').queryByRole('switch')).toBeNull()
    expect(rowFor('slack').queryByRole('button', { name: 'Choose bots' })).toBeNull()

    openBots()

    expect(
      rowFor('gmail')
        .getAllByRole('switch')
        .map(node => node.getAttribute('aria-label'))
    ).toEqual(['Let Writer use this app', 'Let Analyst use this app'])
  })

  it('writes the bot choice through the connector view and reflects what the bot already has', async () => {
    mocks.view = makeView({ access: vi.fn((_app, bot) => (bot.label === 'Writer' ? 'on' : 'off')) })

    render(<ConnectAppsDialog />)
    openBots()

    const [writer, analyst] = rowFor('gmail').getAllByRole('switch')

    expect(writer.getAttribute('aria-checked')).toBe('true')
    expect(analyst.getAttribute('aria-checked')).toBe('false')

    fireEvent.click(analyst)

    await waitFor(() => expect(mocks.view.setAccess).toHaveBeenCalledOnce())
    expect(
      vi
        .mocked(mocks.view.setAccess)
        .mock.calls[0].map(arg => (typeof arg === 'object' ? (arg as { id: string }).id : arg))
    ).toEqual(['gmail', '::analyst', true])
  })

  it('says so, in the row, when the app needs setup before this bot can use it', async () => {
    mocks.view = makeView({ setAccess: vi.fn(async () => 'needsSetup' as const) })

    render(<ConnectAppsDialog />)
    openBots()
    fireEvent.click(rowFor('gmail').getAllByRole('switch')[0])

    expect(await screen.findByText('This app needs setup before a bot can use it. Choose Set up….')).toBeTruthy()
  })

  it('disables a bot whose access could not be read instead of guessing', () => {
    mocks.view = makeView({ access: vi.fn(() => 'unknown' as const) })

    render(<ConnectAppsDialog />)
    openBots()

    expect(rowFor('gmail').getAllByRole('switch')[0].hasAttribute('disabled')).toBe(true)
    expect(rowFor('gmail').getAllByText('Can’t check')).toHaveLength(2)
  })

  it('offers a per-bot sign-in when the bot has the app on but its sign-in is gone', () => {
    mocks.view = makeView({ access: vi.fn(() => 'needsSignIn' as const) })

    render(<ConnectAppsDialog />)
    openBots()
    fireEvent.click(rowFor('gmail').getAllByRole('button', { name: 'Sign in' })[0])

    expect(mocks.view.signInBot).toHaveBeenCalledOnce()
  })

  it('shows only the focused bot, with its switch already open, when opened from that bot', () => {
    closeConnectApps()
    openConnectApps({ name: 'analyst' })

    render(<ConnectAppsDialog />)

    expect(
      rowFor('gmail')
        .getAllByRole('switch')
        .map(node => node.getAttribute('aria-label'))
    ).toEqual(['Let Analyst use this app'])
    expect(rowFor('gmail').queryByRole('button', { name: 'Choose bots' })).toBeNull()
  })
})
