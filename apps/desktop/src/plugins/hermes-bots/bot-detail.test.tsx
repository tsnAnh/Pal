/**
 * The bot pane's Details / Run history / Computer tabs: the details summary, run history merged across
 * every routine (newest first, capped at 20), inline rename, and the header's Share + Delete actions.
 * Older gateways degrade: no run history action, no profile description.
 */

import type * as HermesSdk from '@hermes/plugin-sdk'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import type { atom } from 'nanostores'
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'

import { botJob, mergeRunHistory, RUN_HISTORY_LIMIT } from './bot-detail-model'
import { translateBots } from './i18n-test-helper'
import type { RoutineRun } from './routines-api'
import type { RoutineJob } from './types'

beforeAll(() => {
  Element.prototype.scrollIntoView = vi.fn()
  Element.prototype.hasPointerCapture = vi.fn(() => false)
  Element.prototype.releasePointerCapture = vi.fn()
})

const { appsView, notify, request, saveBotTemplate } = vi.hoisted(() => ({
  appsView: { users: [] as string[] },
  notify: vi.fn(),
  request: vi.fn(async (_method: string, _params: Record<string, unknown>): Promise<unknown> => ({})),
  saveBotTemplate: vi.fn()
}))

vi.mock('@hermes/plugin-sdk', async importOriginal => {
  const sdk = await importOriginal<typeof HermesSdk>()
  const { atom: nanoAtom } = await import('nanostores')

  return {
    ...sdk,
    host: {
      ...sdk.host,
      notify,
      request,
      state: { ...sdk.host.state, focusedSessionOwner: nanoAtom(null) }
    },
    useConnectorApps: () => ({
      catalog: { curated: [{ id: 'gmail', name: 'Gmail' }], others: [{ id: 'slack', name: 'Slack' }] },
      usedBy: (app: { id: string }) => (appsView.users.includes(app.id) ? [{ id: 'local::research' }] : [])
    }),
    usePluginI18n: () => translateBots
  }
})

const { host } = await import('@hermes/plugin-sdk')
const { $lastRoster, $botMeta } = await import('./data')
const { $selectedBot } = await import('./bot-state')
const { $botDeleteRequest } = await import('./bot-detail-state')
const { RoutinesPane } = await import('./cron')

const $focused = host.state.focusedSessionOwner as unknown as ReturnType<typeof atom>

const jobs: RoutineJob[] = [
  { enabled: true, job_id: 'j-a', name: '[bot:research] Morning digest', schedule: 'every 1h', state: 'scheduled' },
  { enabled: true, job_id: 'j-b', name: '[bot:research] Weekly recap', schedule: 'every 1d', state: 'scheduled' }
]

const ACTIONS = ['run', 'history', 'history_output']

function run(id: string, startedAt: string, patch: Partial<RoutineRun> = {}): RoutineRun {
  return {
    duration_seconds: 12,
    finished_at: startedAt,
    has_output: false,
    reason: null,
    run_id: id,
    started_at: startedAt,
    status: 'succeeded',
    ...patch
  }
}

const minute = (n: number) => new Date(Date.UTC(2026, 0, 1, 12, n)).toISOString()

interface Gateway {
  actions: string[]
  describe: unknown
  runs: Record<string, RoutineRun[]>
}

const gateway: Gateway = { actions: ACTIONS, describe: null, runs: {} }

function renderPane() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })

  return render(
    <QueryClientProvider client={client}>
      <RoutinesPane />
    </QueryClientProvider>
  )
}

beforeEach(() => {
  vi.clearAllMocks()
  gateway.actions = ACTIONS
  gateway.describe = {
    model: { default: 'gpt-test' },
    skills: [
      { enabled: true, name: 'a' },
      { enabled: true, name: 'b' },
      { enabled: false, name: 'c' }
    ]
  }
  appsView.users = ['gmail']
  gateway.runs = {
    'j-a': [run('a-old', minute(1)), run('a-new', minute(30), { has_output: true })],
    'j-b': [run('b-mid', minute(10), { reason: 'boom', status: 'failed' })]
  }
  request.mockImplementation(async (method, params) => {
    if (method === 'cron.manage') {
      if (params.action === 'history') {
        return { runs: gateway.runs[String(params.name)] ?? [] }
      }

      if (params.action === 'history_output') {
        return { output: 'digest body', truncated: false }
      }

      return { actions: gateway.actions, jobs, scoped: 'research' }
    }

    if (method === 'profiles.describe') {
      if (!gateway.describe) {
        throw new Error('unsupported')
      }

      return gateway.describe
    }

    return {}
  })
  $botMeta.set({})
  $lastRoster.set([
    {
      connectionId: 'local',
      description: 'Scout — Reads the news every morning',
      name: 'research',
      title: 'Scout'
    }
  ])
  $selectedBot.set('default')
  $focused.set({ connectionId: 'local', profile: 'research' })
  $botDeleteRequest.set(null)
  Object.assign(window, { hermesDesktop: { saveBotTemplate } })
})

afterEach(() => {
  cleanup()
  delete (window as { hermesDesktop?: unknown }).hermesDesktop
})

const openTab = (name: string) => {
  const tab = screen.getByRole('tab', { name })

  fireEvent.mouseDown(tab)
  fireEvent.click(tab)
}

describe('botJob', () => {
  it('drops the title prefix like the agent probe does', () => {
    expect(botJob('Scout — Reads the news', 'Scout')).toBe('Reads the news')
    expect(botJob('  Reads   the news ', null)).toBe('Reads the news')
  })

  it('is empty when the description only repeats the title', () => {
    expect(botJob('scout', 'Scout')).toBe('')
  })

  it('caps the job at 300 characters', () => {
    expect(botJob('x'.repeat(500), null)).toHaveLength(300)
  })
})

describe('mergeRunHistory', () => {
  it('orders runs of every routine newest first', () => {
    const entries = [
      { job: jobs[0], run: run('1', minute(1)) },
      { job: jobs[1], run: run('2', minute(40)) },
      { job: jobs[0], run: run('3', minute(20)) }
    ]

    expect(mergeRunHistory(entries).map(entry => entry.run.run_id)).toEqual(['2', '3', '1'])
  })

  it('keeps at most 20 runs', () => {
    const entries = Array.from({ length: 45 }, (_, index) => ({ job: jobs[0], run: run(`r${index}`, minute(index)) }))
    const merged = mergeRunHistory(entries)

    expect(merged).toHaveLength(RUN_HISTORY_LIMIT)
    expect(merged[0].run.run_id).toBe('r44')
  })
})

describe('the bot pane tabs', () => {
  it('offers Details, Run history and Computer', async () => {
    renderPane()

    expect(await screen.findByRole('tab', { name: 'Details' })).toBeTruthy()
    expect(screen.getByRole('tab', { name: 'Run history' })).toBeTruthy()
    expect(screen.getByRole('tab', { name: 'Computer' })).toBeTruthy()
  })

  it('shows the job, model, skills count and routines on Details', async () => {
    renderPane()

    expect(await screen.findByText('Reads the news every morning')).toBeTruthy()
    expect(await screen.findByText('gpt-test')).toBeTruthy()
    expect(await screen.findByText('2 skills')).toBeTruthy()
    expect(await screen.findByText('Gmail')).toBeTruthy()
    expect(await screen.findByText('Morning digest')).toBeTruthy()
  })

  it('omits model and skills when the gateway cannot describe the profile', async () => {
    gateway.describe = null
    renderPane()

    expect(await screen.findByText('Reads the news every morning')).toBeTruthy()
    expect(screen.queryByText('Model')).toBeNull()
    expect(screen.queryByText('Skills')).toBeNull()
  })

  it('lists runs from all routines newest first with status and expandable output', async () => {
    renderPane()
    await screen.findByText('Morning digest')
    openTab('Run history')

    await waitFor(() => expect(screen.getAllByText(/^Routine: /)).toHaveLength(3))

    expect(screen.getAllByText(/^Routine: /).map(node => node.textContent)).toEqual([
      'Routine: Morning digest',
      'Routine: Weekly recap',
      'Routine: Morning digest'
    ])
    expect(screen.getByText('boom')).toBeTruthy()

    fireEvent.click(screen.getByRole('button', { name: 'View output' }))

    expect(await screen.findByText('digest body')).toBeTruthy()
  })

  it('says so when no routine has run yet', async () => {
    gateway.runs = {}
    renderPane()
    await screen.findByText('Morning digest')
    openTab('Run history')

    expect(await screen.findByText('No runs yet')).toBeTruthy()
  })

  it('degrades on a gateway without run history', async () => {
    gateway.actions = ['run']
    renderPane()
    await screen.findByText('Morning digest')
    openTab('Run history')

    expect(await screen.findByText('Run history needs a newer Hermes.')).toBeTruthy()
    expect(request.mock.calls.some(([, params]) => params.action === 'history')).toBe(false)
  })
})

describe('the bot pane header', () => {
  it('renames inline through the bot meta title', async () => {
    renderPane()
    fireEvent.click(await screen.findByRole('button', { name: 'Scout' }))

    const input = screen.getByRole('textbox', { name: 'Rename' })

    fireEvent.change(input, { target: { value: 'Atlas' } })
    fireEvent.keyDown(input, { key: 'Enter' })

    await waitFor(() => expect(Object.values($botMeta.get()).map(meta => meta.title)).toContain('Atlas'))
  })

  it('leaves the name alone on Escape', async () => {
    renderPane()
    fireEvent.click(await screen.findByRole('button', { name: 'Scout' }))

    const input = screen.getByRole('textbox', { name: 'Rename' })

    fireEvent.change(input, { target: { value: 'Atlas' } })
    fireEvent.keyDown(input, { key: 'Escape' })

    expect(screen.getByRole('button', { name: 'Scout' })).toBeTruthy()
    expect(Object.values($botMeta.get()).map(meta => meta.title)).not.toContain('Atlas')
  })

  it('hands Delete to the roster confirmation flow', async () => {
    renderPane()
    fireEvent.keyDown(await screen.findByRole('button', { name: 'More actions' }), { key: 'Enter' })
    fireEvent.click(await screen.findByRole('menuitem', { name: 'Delete' }))

    expect($botDeleteRequest.get()?.name).toBe('research')
  })

  it('exports a template from Share', async () => {
    request.mockImplementation(async method =>
      method === 'profiles.template.export' ? { data: 'QUJD', filename: 'research.hermesbot' } : { jobs: [], scoped: 'research' }
    )
    saveBotTemplate.mockResolvedValue({ canceled: true, saved: false })
    renderPane()
    fireEvent.keyDown(await screen.findByRole('button', { name: 'More actions' }), { key: 'Enter' })
    fireEvent.click(await screen.findByRole('menuitem', { name: 'Export template…' }))

    await waitFor(() => expect(saveBotTemplate).toHaveBeenCalled())
    await act(async () => undefined)
  })
})
