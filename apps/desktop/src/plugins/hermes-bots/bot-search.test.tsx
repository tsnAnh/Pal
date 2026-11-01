/**
 * Bot Mode search: one box, grouped results (Bots, Group chats, Routines, Messages), keyboard
 * navigation, and selection that opens through the canonical paths. Messages need the host's
 * persisted-session search; without it the box still works and says so.
 */

import type * as HermesSdk from '@hermes/plugin-sdk'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'

import { translateBots } from './i18n-test-helper'

beforeAll(() => {
  Element.prototype.scrollIntoView = vi.fn()
  Element.prototype.hasPointerCapture = vi.fn(() => false)
  Element.prototype.releasePointerCapture = vi.fn()
})

const { openGroupChat, openRosterBot, request, searchPersistedSessions } = vi.hoisted(() => ({
  openGroupChat: vi.fn(),
  openRosterBot: vi.fn(async () => true),
  request: vi.fn(async (_method: string, _params: Record<string, unknown>): Promise<unknown> => ({})),
  searchPersistedSessions: vi.fn()
}))

vi.mock('./roster-actions', () => ({ openRosterBot }))
vi.mock('./group-chat-view', () => ({ openGroupChat }))

vi.mock('@hermes/plugin-sdk', async importOriginal => {
  const sdk = await importOriginal<typeof HermesSdk>()

  return {
    ...sdk,
    host: { ...sdk.host, request, searchPersistedSessions },
    usePluginI18n: () => translateBots
  }
})

const sdkModule = await import('@hermes/plugin-sdk')
const { $botMeta, $lastRoster } = await import('./data')
const { $groupChats } = await import('./group-chat')
const { $botSearchOpen, openBotSearch } = await import('./bot-search-state')
const { $routineOpenRequest } = await import('./bot-detail-state')
const { BotSearchDialog } = await import('./bot-search')

const roster = [
  { connectionId: 'local', description: 'Scout — Tracks competitor pricing', name: 'scout', title: 'Scout' },
  { connectionId: 'local', description: 'Writer — Drafts newsletters', name: 'writer', title: 'Writer' }
]

const jobs = [
  {
    enabled: true,
    job_id: 'j-1',
    name: '[bot:scout] Pricing sweep',
    prompt: 'Check competitor pricing pages',
    schedule: 'every 1d',
    state: 'scheduled'
  }
]

function renderSearch() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })

  render(
    <QueryClientProvider client={client}>
      <BotSearchDialog />
    </QueryClientProvider>
  )
  act(() => openBotSearch())
}

const type = async (value: string) => {
  fireEvent.change(await screen.findByRole('textbox', { name: 'Search' }), { target: { value } })
}

beforeEach(() => {
  vi.clearAllMocks()
  request.mockImplementation(async () => ({ jobs, scoped: 'scout' }))
  searchPersistedSessions.mockImplementation(async (_route, options: { profile: string; query: string }) => ({
    results: (options.profile === 'scout'
      ? [
          { session_id: 's-1', snippet: 'we raised the pricing last week', title: 'Bot Chat' },
          { session_id: 's-2', snippet: 'pricing in a side chat', title: 'Side chat' }
        ]
      : []
    ).filter(result => result.snippet.includes(options.query))
  }))
  $botMeta.set({})
  $lastRoster.set(roster)
  $groupChats.set({
    'Launch room': {
      watermarks: {},
      log: [{ at: 1, from: { kind: 'user', name: 'me' }, id: 'm1', text: 'pricing decision is due friday' }],
      members: [{ name: 'scout' }, { name: 'writer' }]
    }
  })
  $routineOpenRequest.set(null)
  $botSearchOpen.set(false)
})

afterEach(() => {
  cleanup()
  act(() => $botSearchOpen.set(false))
})

describe('Bot Mode search', () => {
  it('shows a hint before anything is typed', async () => {
    renderSearch()

    expect(await screen.findByText(/Type to search across/)).toBeTruthy()
  })

  it('groups bots, group chats, routines and messages', async () => {
    renderSearch()
    await type('pricing')

    const list = await screen.findByRole('listbox')

    await waitFor(() =>
      expect(
        within(list)
          .getAllByRole('group')
          .map(group => group.firstChild?.textContent)
      ).toEqual(['Bots', 'Routines', 'Messages'])
    )

    expect(within(list).getByText('Tracks competitor pricing')).toBeTruthy()
    expect(within(list).getByText('Pricing sweep')).toBeTruthy()
    expect(within(list).getByText('we raised the pricing last week')).toBeTruthy()
    expect(within(list).getByText('pricing decision is due friday')).toBeTruthy()
    expect(within(list).queryByText('pricing in a side chat')).toBeNull()
  })

  it('matches group chats by member', async () => {
    renderSearch()
    await type('writer')

    expect(await screen.findByText('Launch room')).toBeTruthy()
    expect(screen.getByText('2 members')).toBeTruthy()
  })

  it('opens a bot through the canonical open path', async () => {
    renderSearch()
    await type('writer')
    fireEvent.click(await screen.findByText('Drafts newsletters'))

    expect(openRosterBot).toHaveBeenCalledWith(expect.objectContaining({ name: 'writer' }))
    expect($botSearchOpen.get()).toBe(false)
  })

  it('opens a group chat result', async () => {
    renderSearch()
    await type('launch')
    fireEvent.click(await screen.findByText('2 members'))

    expect(openGroupChat).toHaveBeenCalledWith('Launch room', expect.anything())
  })

  it('opens a routine through its bot', async () => {
    renderSearch()
    await type('sweep')
    fireEvent.click(await screen.findByText('Pricing sweep'))

    expect(openRosterBot).toHaveBeenCalledWith(expect.objectContaining({ name: 'scout' }))
    expect($routineOpenRequest.get()).toEqual({ botKey: 'local::scout', jobId: 'j-1' })
  })

  it('opens the owning bot chat for a message hit', async () => {
    renderSearch()
    await type('raised')
    fireEvent.click(await screen.findByText('we raised the pricing last week'))

    expect(openRosterBot).toHaveBeenCalledWith(expect.objectContaining({ name: 'scout' }))
    expect(searchPersistedSessions.mock.calls.map(call => call[1])).toContainEqual(
      expect.objectContaining({ profile: 'scout', query: 'raised' })
    )
  })

  it('finds the Bot Chat hit even when side chats fill the server page first', async () => {
    searchPersistedSessions.mockImplementation(async (_route, options: { limit?: number; profile: string }) => {
      const rows = [
        ...Array.from({ length: 8 }, (_, index) => ({
          session_id: `side-${index}`,
          snippet: 'pricing in a side chat',
          title: 'Side chat'
        })),
        { session_id: 's-1', snippet: 'pricing in the bot chat', title: 'Bot Chat' }
      ]

      return { results: options.profile === 'scout' ? rows.slice(0, options.limit ?? rows.length) : [] }
    })
    renderSearch()
    await type('pricing')

    expect(await screen.findByText('pricing in the bot chat')).toBeTruthy()
  })

  it('searches at most four bots at a time', async () => {
    let inFlight = 0
    let peak = 0

    $lastRoster.set(
      Array.from({ length: 12 }, (_, index) => ({ connectionId: 'local', name: `bot-${index}`, title: `Bot ${index}` }))
    )
    searchPersistedSessions.mockImplementation(async () => {
      inFlight += 1
      peak = Math.max(peak, inFlight)
      await new Promise(resolve => setTimeout(resolve, 15))
      inFlight -= 1

      return { results: [] }
    })
    renderSearch()
    await type('pricing')
    await waitFor(() => expect(searchPersistedSessions).toHaveBeenCalledTimes(12))

    expect(peak).toBeLessThanOrEqual(4)
  })

  it('is keyboard navigable', async () => {
    renderSearch()
    await type('writer')
    await screen.findByText('Drafts newsletters')

    const input = screen.getByRole('textbox', { name: 'Search' })

    fireEvent.keyDown(input, { key: 'ArrowDown' })
    fireEvent.keyDown(input, { key: 'ArrowUp' })
    fireEvent.keyDown(input, { key: 'Enter' })

    expect(openRosterBot).toHaveBeenCalledTimes(1)
  })

  it('moves the selection with the arrow keys', async () => {
    renderSearch()
    await type('pricing')
    await screen.findByText('Pricing sweep')

    const input = screen.getByRole('textbox', { name: 'Search' })

    fireEvent.keyDown(input, { key: 'ArrowDown' })

    const options = screen.getAllByRole('option')

    expect(options[0].getAttribute('aria-selected')).toBe('false')
    expect(options[1].getAttribute('aria-selected')).toBe('true')
  })

  it('shows a no-results state', async () => {
    renderSearch()
    await type('zzzz')

    expect(await screen.findByText('No results for “zzzz”')).toBeTruthy()
  })

  it('still searches bots, rooms and routines on a host without message search', async () => {
    const host = sdkModule.host as unknown as Record<string, unknown>
    const original = host.searchPersistedSessions

    host.searchPersistedSessions = undefined

    try {
      renderSearch()
      await type('pricing')

      expect(await screen.findByText('Pricing sweep')).toBeTruthy()
      expect(screen.getByText('Message search needs a newer Hermes.')).toBeTruthy()
    } finally {
      host.searchPersistedSessions = original
    }
  })

  it('opens on Cmd+K only while Bot Mode is on screen', async () => {
    render(
      <QueryClientProvider client={new QueryClient()}>
        <BotSearchDialog />
      </QueryClientProvider>
    )

    fireEvent.keyDown(window, { ctrlKey: true, key: 'k' })
    expect($botSearchOpen.get()).toBe(false)

    window.document.documentElement.dataset.botMode = ''

    try {
      fireEvent.keyDown(window, { key: 'k', metaKey: true })
      expect($botSearchOpen.get()).toBe(true)
    } finally {
      delete window.document.documentElement.dataset.botMode
    }
  })
})
