/**
 * Plain-language schedules in the create dialog: what is typed is checked by the gateway and shown back in
 * its normalized form, a cadence under five minutes is refused with a clear message (locally for the
 * obvious cases, by the gateway otherwise), and a gateway that cannot preview still gets the local rule.
 */

import type * as HermesSdk from '@hermes/plugin-sdk'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'

import { translateBots } from './i18n-test-helper'
import { scheduleReasonText, scheduleTooFrequent, supportsRoutineAction } from './routines-api'

beforeAll(() => {
  Element.prototype.scrollIntoView = vi.fn()
  Element.prototype.hasPointerCapture = vi.fn(() => false)
  Element.prototype.releasePointerCapture = vi.fn()
})

const { notify, request } = vi.hoisted(() => ({
  notify: vi.fn(),
  request: vi.fn(async (_method: string, _params: Record<string, unknown>): Promise<unknown> => ({}))
}))

vi.mock('@hermes/plugin-sdk', async importOriginal => {
  const sdk = await importOriginal<typeof HermesSdk>()

  return { ...sdk, host: { ...sdk.host, notify, request }, usePluginI18n: () => translateBots }
})

const { CreateRoutineDialog } = await import('./cron')

const PREVIEW_ACTIONS = ['schedule_preview']

function chooseAdvanced() {
  const field = screen.getByText('When to run').parentElement!

  fireEvent.click(within(field).getAllByRole('combobox')[0])
  fireEvent.click(screen.getByRole('option', { name: 'Advanced…' }))
}

function type(schedule: string) {
  fireEvent.change(screen.getByPlaceholderText(/every weekday at 9am/), { target: { value: schedule } })
}

function fillRequiredFields() {
  fireEvent.change(screen.getByPlaceholderText('Morning briefing'), { target: { value: 'Digest' } })
  fireEvent.change(screen.getByPlaceholderText(/Summarize my unread Slack threads/), { target: { value: 'Do it.' } })
}

const createButton = () => screen.getByRole('button', { name: 'Create cron' })
const previews = () => request.mock.calls.filter(([, params]) => params.action === 'schedule_preview')

function renderDialog(actions: string[] | undefined = PREVIEW_ACTIONS, onClose = () => undefined) {
  return render(<CreateRoutineDialog actions={actions} bot={{ name: 'ops' }} onClose={onClose} open />)
}

beforeEach(() => {
  vi.clearAllMocks()
  request.mockImplementation(async (_method, params) => {
    if (params.action !== 'schedule_preview') {
      return { success: true }
    }

    return String(params.schedule).includes('minute')
      ? { error: 'x', reason: 'too_frequent', success: false }
      : {
          kind: 'cron',
          next_run_at: new Date(Date.now() + 3_600_000).toISOString(),
          schedule: '0 9 * * 1-5',
          success: true
        }
  })
})

afterEach(() => cleanup())

describe('the local cadence rule', () => {
  it.each([
    ['every 2 minutes', true],
    ['every 4m', true],
    ['3m', true],
    ['every 1 min', true],
    ['every 5 minutes', false],
    ['every 5m', false],
    ['every 2h', false],
    ['every weekday at 9am', false],
    ['0 9 * * 1-5', false]
  ])('%s is too frequent: %s', (schedule, expected) => {
    expect(scheduleTooFrequent(schedule)).toBe(expected)
  })

  it('knows only the actions a gateway listed', () => {
    expect(supportsRoutineAction(undefined, 'run')).toBe(false)
    expect(supportsRoutineAction([], 'run')).toBe(false)
    expect(supportsRoutineAction(['run'], 'run')).toBe(true)
    expect(supportsRoutineAction(['run'], 'history')).toBe(false)
  })

  it('turns a refusal reason into its message and falls back to the gateway text', () => {
    const c = translateBotsSchedule()

    expect(scheduleReasonText('too_frequent', c)).toBe('Routines can run at most once every 5 minutes.')
    expect(scheduleReasonText('unrecognized', c)).toMatch(/not understood/)
    expect(scheduleReasonText('other', c)).toBe(c.invalid)
  })
})

function translateBotsSchedule() {
  return {
    checking: '',
    invalid: 'That schedule is not valid.',
    nextRun: () => '',
    placeholder: '',
    runs: () => '',
    tooFrequent: 'Routines can run at most once every 5 minutes.',
    unrecognized: 'That schedule was not understood.'
  }
}

describe('typing a schedule in plain language', () => {
  it('shows the normalized schedule back and allows creating', async () => {
    renderDialog()
    fillRequiredFields()
    chooseAdvanced()
    type('every weekday at 9am')

    expect(await screen.findByText(/Runs Weekdays at 9:00/)).toBeTruthy()
    expect(screen.getByText(/Next run in/)).toBeTruthy()
    expect(previews()).toEqual([
      ['cron.manage', { action: 'schedule_preview', profile: 'ops', schedule: 'every weekday at 9am' }]
    ])
    expect(createButton()).toHaveProperty('disabled', false)
  })

  it('refuses a cadence under five minutes before asking the gateway', async () => {
    renderDialog()
    fillRequiredFields()
    chooseAdvanced()
    type('every 2 minutes')

    expect(await screen.findByRole('alert')).toHaveProperty(
      'textContent',
      'Routines can run at most once every 5 minutes.'
    )
    expect(createButton()).toHaveProperty('disabled', true)
    expect(previews()).toHaveLength(0)
  })

  it('shows the gateway’s refusal for what only it can judge', async () => {
    renderDialog()
    fillRequiredFields()
    chooseAdvanced()
    type('every single minute')

    expect(await screen.findByRole('alert')).toHaveProperty(
      'textContent',
      'Routines can run at most once every 5 minutes.'
    )
    expect(createButton()).toHaveProperty('disabled', true)
  })

  it('names a schedule it cannot read and offers examples', async () => {
    request.mockImplementation(async () => ({ error: 'x', reason: 'unrecognized', success: false }))
    renderDialog()
    fillRequiredFields()
    chooseAdvanced()
    type('when pigs fly')

    expect(await screen.findByText(/every weekday at 9am/, { selector: '[role="alert"]' })).toBeTruthy()
    expect(createButton()).toHaveProperty('disabled', true)
  })

  it('re-enables creating once the text is fixed', async () => {
    renderDialog()
    fillRequiredFields()
    chooseAdvanced()
    type('every 2 minutes')
    await screen.findByRole('alert')

    type('every 2 hours')

    await waitFor(() => expect(createButton()).toHaveProperty('disabled', false))
  })
})

describe('a gateway that cannot preview', () => {
  it('never calls schedule_preview, still enforces the local rule, and lets a phrase through to the gateway', async () => {
    renderDialog([])
    fillRequiredFields()
    chooseAdvanced()
    type('every weekday at 9am')

    await new Promise(resolve => setTimeout(resolve, 600))
    expect(previews()).toHaveLength(0)
    expect(screen.queryByText(/Runs Weekdays/)).toBeNull()
    expect(createButton()).toHaveProperty('disabled', false)

    type('every 3m')

    expect(await screen.findByRole('alert')).toBeTruthy()
    expect(createButton()).toHaveProperty('disabled', true)
  })
})

describe('creating a routine', () => {
  it('shows the gateway’s refusal inside the dialog and keeps it open', async () => {
    const onClose = vi.fn()

    request.mockImplementation(async (_method, params) =>
      params.action === 'add' ? { error: 'x', reason: 'too_frequent', success: false } : { success: true }
    )
    renderDialog([], onClose)
    fillRequiredFields()
    fireEvent.click(createButton())

    expect(await screen.findByText('Routines can run at most once every 5 minutes.')).toBeTruthy()
    expect(onClose).not.toHaveBeenCalled()
    expect(notify).not.toHaveBeenCalled()
  })

  it('creates a one-shot as a delay, not a repeating interval, and is not held to the cadence minimum', async () => {
    renderDialog([])
    fillRequiredFields()

    const field = screen.getByText('When to run').parentElement!

    fireEvent.click(within(field).getAllByRole('combobox')[0])
    fireEvent.click(screen.getByRole('option', { name: 'Once, in…' }))
    fireEvent.change(screen.getByPlaceholderText('30'), { target: { value: '2' } })
    expect(createButton()).toHaveProperty('disabled', false)
    fireEvent.click(createButton())

    await waitFor(() => expect(request).toHaveBeenCalled())
    expect(request.mock.calls[0][1]).toMatchObject({ action: 'add', schedule: 'in 2m' })
  })

  it('closes and confirms when the gateway accepts it', async () => {
    const onClose = vi.fn()

    renderDialog([], onClose)
    fillRequiredFields()
    fireEvent.click(createButton())

    await waitFor(() => expect(onClose).toHaveBeenCalled())
    expect(notify).toHaveBeenCalledWith(expect.objectContaining({ kind: 'success' }))
  })
})
