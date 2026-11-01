/**
 * What a routine's inspector offers beyond reading it: the Active switch, Test now (a real run, with a
 * running state and a short failure reason), the recent runs with their output, and the webhook trigger
 * (key shown once). Each control degrades honestly against a gateway that predates its action.
 */

import type * as HermesSdk from '@hermes/plugin-sdk'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'

import { translateBots } from './i18n-test-helper'
import type { RoutineRun, TriggerStatus } from './routines-api'
import type { RoutineJob } from './types'

beforeAll(() => {
  Element.prototype.scrollIntoView = vi.fn()
  Element.prototype.hasPointerCapture = vi.fn(() => false)
  Element.prototype.releasePointerCapture = vi.fn()
})

const { notifyError, request } = vi.hoisted(() => ({
  notifyError: vi.fn(),
  request: vi.fn(async (_method: string, _params: Record<string, unknown>): Promise<unknown> => ({}))
}))

vi.mock('@hermes/plugin-sdk', async importOriginal => {
  const sdk = await importOriginal<typeof HermesSdk>()

  return { ...sdk, host: { ...sdk.host, notifyError, request }, usePluginI18n: () => translateBots }
})

const { RoutineDetailDialog } = await import('./cron')

const ALL_ACTIONS = [
  'run',
  'history',
  'history_output',
  'schedule_preview',
  'trigger_status',
  'trigger_issue',
  'trigger_remove'
]

const job: RoutineJob = {
  enabled: true,
  job_id: 'job-1',
  name: '[bot:notetaker] Morning digest',
  prompt_preview: 'Summarize yesterday.',
  schedule: 'every 1440m',
  state: 'scheduled'
}

const paused: RoutineJob = { ...job, enabled: false, state: 'paused' }

interface Gateway {
  run: { error?: string; mode?: string; reason?: string; started: boolean }
  runs: RoutineRun[]
  runOnStart: null | RoutineRun[]
  trigger: TriggerStatus
  issued: Array<{ created_at: string; key: string; url: string }>
}

const gateway: Gateway = {
  issued: [],
  run: { started: true },
  runOnStart: null,
  runs: [],
  trigger: { available: true, blocked_by: null, configured: false }
}

const calls = (action: string) =>
  request.mock.calls.filter(([, params]) => params.action === action).map(([, params]) => params)

function runRecord(patch: Partial<RoutineRun> = {}): RoutineRun {
  return {
    duration_seconds: 12,
    finished_at: new Date().toISOString(),
    has_output: false,
    reason: null,
    run_id: `run-${Math.random()}`,
    started_at: new Date().toISOString(),
    status: 'succeeded',
    ...patch
  }
}

beforeEach(() => {
  vi.clearAllMocks()
  gateway.run = { started: true }
  gateway.runs = []
  gateway.runOnStart = null
  gateway.issued = []
  gateway.trigger = { available: true, blocked_by: null, configured: false }
  request.mockImplementation(async (_method, params) => {
    switch (params.action) {
      case 'run':
        if (gateway.runOnStart) {
          gateway.runs = gateway.runOnStart
        }

        return { success: gateway.run.started, ...gateway.run }

      case 'history':
        return { runs: gateway.runs, success: true }

      case 'history_output':
        return { output: `output of ${params.run_id}`, run_id: params.run_id, success: true, truncated: false }

      case 'trigger_status':
        return { success: true, ...gateway.trigger }
      case 'trigger_issue': {
        const issued = {
          created_at: 'now',
          key: `key-${gateway.issued.length + 1}`,
          url: 'http://localhost:8644/webhooks/routine-job-1'
        }

        gateway.issued.push(issued)
        gateway.trigger = { available: true, blocked_by: null, configured: true, url: issued.url }

        return { success: true, ...issued }
      }

      case 'trigger_remove':
        gateway.trigger = { available: true, blocked_by: null, configured: false }

        return { removed: true, success: true }

      default:
        return { success: true }
    }
  })
})

afterEach(() => cleanup())

function renderInspector(routine: RoutineJob = job, { actions = ALL_ACTIONS }: { actions?: string[] } = {}) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })

  return render(
    <QueryClientProvider client={client}>
      <RoutineDetailDialog
        actions={actions}
        job={routine}
        onClose={() => undefined}
        open
        owner={{ name: 'notetaker' }}
      />
    </QueryClientProvider>
  )
}

describe('against a gateway that predates routine operations', () => {
  it('disables Test now and explains, without calling an action it does not have', async () => {
    renderInspector(job, { actions: [] })

    expect(await screen.findByText(/Testing from here needs a newer Hermes gateway/)).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Test now' })).toHaveProperty('disabled', true)
    expect(screen.getByText(/Run history needs a newer Hermes gateway/)).toBeTruthy()
    expect(screen.getByText(/Triggers need a newer Hermes gateway/)).toBeTruthy()
    expect(request).not.toHaveBeenCalled()
  })

  it('stays the read-only inspector when no owner is given', () => {
    render(<RoutineDetailDialog job={job} onClose={() => undefined} open />)

    expect(screen.queryByRole('button', { name: 'Test now' })).toBeNull()
    expect(screen.queryByText('Triggers')).toBeNull()
  })
})

describe('Test now', () => {
  it('says it runs for real before anything is clicked', async () => {
    renderInspector()

    expect(await screen.findByText(/Runs this routine for real, right now/)).toBeTruthy()
  })

  it('starts the routine in the bot’s profile and shows a running state until the run ends', async () => {
    renderInspector()
    await waitFor(() => expect(calls('history')).toHaveLength(1))

    const started = runRecord({ finished_at: null, status: 'running' })

    gateway.runOnStart = [started]
    fireEvent.click(screen.getByRole('button', { name: 'Test now' }))

    await waitFor(() => expect(calls('run')).toEqual([{ action: 'run', name: 'job-1', profile: 'notetaker' }]))

    const running = await screen.findByRole('button', { name: /Running/ })

    expect(running).toHaveProperty('disabled', true)

    gateway.runs = [{ ...started, finished_at: new Date().toISOString(), status: 'succeeded' }]

    expect(await screen.findByText('The test finished.', undefined, { timeout: 6000 })).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Test now' })).toHaveProperty('disabled', false)
  }, 10000)

  it('reports a failed run with its short reason', async () => {
    renderInspector()
    await waitFor(() => expect(calls('history')).toHaveLength(1))

    gateway.runOnStart = [runRecord({ reason: 'The provider timed out', status: 'failed' })]
    fireEvent.click(screen.getByRole('button', { name: 'Test now' }))

    expect(await screen.findByText('The test failed: The provider timed out')).toBeTruthy()
    expect(screen.getAllByText('The provider timed out').length).toBeGreaterThan(0)
  })

  it('finishes against a server clock far from the client clock', async () => {
    renderInspector()
    await waitFor(() => expect(calls('history')).toHaveLength(1))

    const hourAgo = new Date(Date.now() - 3_600_000).toISOString()

    gateway.runOnStart = [runRecord({ finished_at: hourAgo, started_at: hourAgo, status: 'succeeded' })]
    fireEvent.click(screen.getByRole('button', { name: 'Test now' }))

    expect(await screen.findByText('The test finished.', undefined, { timeout: 6000 })).toBeTruthy()
  }, 10000)

  it('does not wait on a history it cannot read', async () => {
    renderInspector(job, { actions: ['run'] })

    fireEvent.click(await screen.findByRole('button', { name: 'Test now' }))

    expect(await screen.findByText('The test started.')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Test now' })).toHaveProperty('disabled', false)
    expect(calls('history')).toHaveLength(0)
  })

  it('stops watching a run that never reports back', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })

    try {
      renderInspector()
      await waitFor(() => expect(calls('history')).toHaveLength(1))

      gateway.runOnStart = []
      fireEvent.click(screen.getByRole('button', { name: 'Test now' }))
      await screen.findByRole('button', { name: /Running/ })
      await vi.advanceTimersByTimeAsync(11 * 60_000)

      expect(await screen.findByText(/no longer waiting/i)).toBeTruthy()
      expect(screen.getByRole('button', { name: 'Test now' })).toHaveProperty('disabled', false)
    } finally {
      vi.useRealTimers()
    }
  })

  it('never shows a raw transport error as the reason a test could not start', async () => {
    request.mockImplementation(async (_method, params) => {
      if (params.action === 'run') {
        throw new Error('ECONNRESET 10.0.0.7:9119')
      }

      return { runs: [], success: true }
    })
    renderInspector()

    fireEvent.click(await screen.findByRole('button', { name: 'Test now' }))

    expect(await screen.findByText('Could not start the test: The run could not start.')).toBeTruthy()
    expect(screen.queryByText(/ECONNRESET/)).toBeNull()
  })

  it.each([
    ['already_running', 'Could not start the test: This routine is already running.'],
    ['paused', 'Could not start the test: Turn the routine on before testing it.'],
    ['unavailable', 'Could not start the test: The run could not start.']
  ])('reports a run that never started (%s)', async (reason, copy) => {
    gateway.run = { reason, started: false }
    renderInspector()
    await waitFor(() => expect(calls('history')).toHaveLength(1))

    fireEvent.click(screen.getByRole('button', { name: 'Test now' }))

    expect(await screen.findByText(copy)).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Test now' })).toHaveProperty('disabled', false)
  })

  it('reports a run handed to the gateway ticker as queued, not running', async () => {
    gateway.run = { mode: 'queued', started: true }
    renderInspector()
    await waitFor(() => expect(calls('history')).toHaveLength(1))

    fireEvent.click(screen.getByRole('button', { name: 'Test now' }))

    expect(await screen.findByText(/Test queued/)).toBeTruthy()
  })

  it('cannot test a paused routine', async () => {
    renderInspector(paused)

    expect(await screen.findByText('Turn the routine on before testing it.')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Test now' })).toHaveProperty('disabled', true)
  })

  it('shows a run already in flight on the button without a click', async () => {
    gateway.runs = [runRecord({ finished_at: null, status: 'running' })]
    renderInspector()

    expect(await screen.findByRole('button', { name: /Running/ })).toHaveProperty('disabled', true)
  })
})

describe('the Active switch', () => {
  it('shows the routine as paused and resumes it through the bot’s profile', async () => {
    renderInspector(paused)

    const dialog = screen.getByRole('dialog')
    const toggle = within(dialog).getByRole('switch', { name: 'Active' })

    expect(toggle.getAttribute('aria-checked')).toBe('false')

    fireEvent.click(toggle)

    await waitFor(() => expect(calls('resume')).toEqual([{ action: 'resume', name: 'job-1', profile: 'notetaker' }]))
  })

  it('pauses an active routine and rolls back visibly when the gateway refuses', async () => {
    request.mockImplementation(async (_method, params) => {
      if (params.action === 'pause') {
        throw new Error('gateway down')
      }

      return params.action === 'history' ? { runs: [], success: true } : { success: true, ...gateway.trigger }
    })
    renderInspector()

    const toggle = within(screen.getByRole('dialog')).getByRole('switch', { name: 'Active' })

    fireEvent.click(toggle)

    await waitFor(() => expect(notifyError).toHaveBeenCalled())
    expect(toggle.getAttribute('aria-checked')).toBe('true')
  })
})

describe('run history', () => {
  it('lists each run with its status, duration and reason, newest first as sent', async () => {
    gateway.runs = [
      runRecord({ duration_seconds: 4, run_id: 'a', status: 'succeeded' }),
      runRecord({ duration_seconds: 125, reason: 'quota exceeded', run_id: 'b', status: 'failed' }),
      runRecord({ finished_at: null, run_id: 'c', status: 'running' })
    ]
    renderInspector()

    expect(await screen.findByText('Succeeded')).toBeTruthy()
    expect(screen.getByText('Failed')).toBeTruthy()
    expect(screen.getByText('quota exceeded')).toBeTruthy()
    expect(screen.getByText('Running')).toBeTruthy()
    expect(screen.getByText(/· 4s/)).toBeTruthy()
    expect(screen.getByText(/· 2m/)).toBeTruthy()
  })

  it('says so when there are no runs yet', async () => {
    renderInspector()

    expect(await screen.findByText('No runs yet.')).toBeTruthy()
  })

  it('reads a run’s output on demand and only for runs that saved one', async () => {
    gateway.runs = [runRecord({ has_output: true, run_id: 'with-output' }), runRecord({ run_id: 'silent' })]
    renderInspector()

    const view = await screen.findByRole('button', { name: 'View output' })

    expect(screen.getAllByRole('button', { name: 'View output' })).toHaveLength(1)
    expect(calls('history_output')).toHaveLength(0)

    fireEvent.click(view)

    expect(await screen.findByText('output of with-output')).toBeTruthy()
    expect(calls('history_output')).toEqual([
      { action: 'history_output', name: 'job-1', profile: 'notetaker', run_id: 'with-output' }
    ])

    fireEvent.click(screen.getByRole('button', { name: 'Hide output' }))

    expect(screen.queryByText('output of with-output')).toBeNull()
  })

  it('offers a retry when the history cannot be read', async () => {
    request.mockImplementation(async (_method, params) => {
      if (params.action === 'history') {
        throw new Error('boom')
      }

      return { success: true, ...gateway.trigger }
    })
    renderInspector()

    expect(await screen.findByText('Could not load the run history.')).toBeTruthy()
    expect(screen.getAllByRole('button', { name: 'Retry' }).length).toBeGreaterThan(0)
  })
})

describe('the webhook trigger', () => {
  const openMenu = () => {
    const add = screen.getByRole('button', { name: 'Add trigger' })

    fireEvent.pointerDown(add, { button: 0, ctrlKey: false, pointerType: 'mouse' })
  }

  it('is disabled with the reason when the Webhook platform is off', async () => {
    gateway.trigger = { available: false, blocked_by: 'webhook_disabled', configured: false }
    renderInspector()

    expect(await screen.findByText(/Turn on the Webhook platform for this bot/)).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Add trigger' })).toHaveProperty('disabled', true)
  })

  it('is disabled with the reason when the gateway is not running', async () => {
    gateway.trigger = { available: false, blocked_by: 'gateway_stopped', configured: false }
    renderInspector()

    expect(await screen.findByText(/Start this bot’s gateway/)).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Add trigger' })).toHaveProperty('disabled', true)
  })

  it('creates a webhook, shows the address and key once, and never shows the key again', async () => {
    renderInspector()
    await screen.findByRole('button', { name: 'Add trigger' })

    openMenu()
    fireEvent.click(await screen.findByRole('menuitem', { name: 'Webhook' }))

    expect(await screen.findByText('Webhook trigger ready')).toBeTruthy()
    expect(screen.getByText('key-1')).toBeTruthy()
    expect(screen.getAllByText('http://localhost:8644/webhooks/routine-job-1').length).toBeGreaterThan(0)
    expect(screen.getByText(/shown only once/)).toBeTruthy()
    expect(calls('trigger_issue')).toEqual([{ action: 'trigger_issue', name: 'job-1', profile: 'notetaker' }])

    fireEvent.click(screen.getByRole('button', { name: 'Done' }))

    await waitFor(() => expect(screen.queryByText('key-1')).toBeNull())
    expect(screen.getByRole('button', { name: 'Regenerate key' })).toBeTruthy()
    expect(screen.getByRole('dialog').textContent).not.toContain('key-1')
  })

  it('regenerates behind a confirmation and shows only the new key', async () => {
    gateway.trigger = {
      available: true,
      blocked_by: null,
      configured: true,
      url: 'http://localhost:8644/webhooks/routine-job-1'
    }
    renderInspector()

    fireEvent.click(await screen.findByRole('button', { name: 'Regenerate key' }))

    expect(calls('trigger_issue')).toHaveLength(0)
    expect(screen.getByText('Regenerate the key?')).toBeTruthy()

    fireEvent.click(screen.getByRole('button', { name: 'Regenerate' }))

    expect(await screen.findByText('key-1')).toBeTruthy()
    expect(calls('trigger_issue')).toHaveLength(1)
  })

  it('removes the trigger behind a confirmation', async () => {
    gateway.trigger = {
      available: true,
      blocked_by: null,
      configured: true,
      url: 'http://localhost:8644/webhooks/routine-job-1'
    }
    renderInspector()

    fireEvent.click(await screen.findByRole('button', { name: 'Remove trigger' }))
    expect(calls('trigger_remove')).toHaveLength(0)

    fireEvent.click(screen.getByRole('button', { name: 'Remove' }))

    await waitFor(() =>
      expect(calls('trigger_remove')).toEqual([{ action: 'trigger_remove', name: 'job-1', profile: 'notetaker' }])
    )
    expect(await screen.findByRole('button', { name: 'Add trigger' })).toBeTruthy()
  })

  it('says when another webhook already uses the address', async () => {
    request.mockImplementation(async (_method, params) => {
      if (params.action === 'trigger_issue') {
        return { error: 'x', reason: 'conflict', success: false }
      }

      return params.action === 'history' ? { runs: [], success: true } : { success: true, ...gateway.trigger }
    })
    renderInspector()
    await screen.findByRole('button', { name: 'Add trigger' })

    openMenu()
    fireEvent.click(await screen.findByRole('menuitem', { name: 'Webhook' }))

    expect(await screen.findByRole('alert')).toHaveProperty(
      'textContent',
      'Another webhook already uses this routine’s address.'
    )
  })
})
