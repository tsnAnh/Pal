import { fireEvent, render, waitFor } from '@testing-library/react'
import type { ReactNode } from 'react'
import { beforeEach, expect, it, vi } from 'vitest'

import type { DisplayLease } from './screen-connection'
import type * as ScreenConnection from './screen-connection'
import type { RosterRow } from './types'

const submit = vi.hoisted(() => vi.fn(() => true))
const notify = vi.hoisted(() => vi.fn())
const openBotScreen = vi.hoisted(() => vi.fn())

vi.mock('@hermes/plugin-sdk', async () => {
  const { useStore } = await import('@nanostores/react')
  const { onGatewayEvent } = await import('../../contrib/events')

  return {
    Button: ({ children, ...props }: React.ButtonHTMLAttributes<HTMLButtonElement>) => (
      <button {...props}>{children}</button>
    ),
    Codicon: () => null,
    useValue: useStore,
    host: {
      composer: { submit },
      notify,
      onEvent: onGatewayEvent,
      state: { focusedStoredSessionId: { get: () => '', listen: () => () => undefined, subscribe: () => () => undefined } }
    }
  }
})
vi.mock('./routing', () => ({ botRosterMeta: () => null }))
vi.mock('./labels', () => ({ displayName: (bot: RosterRow) => bot.name }))
vi.mock('./screen-open', () => ({ openBotScreen }))
vi.mock('./chat-empty', () => ({ botForChat: (roster: RosterRow[]) => roster[0] ?? null }))
vi.mock('./data', async () => {
  const { atom } = await import('nanostores')

  return {
    $botMeta: atom({}),
    $lastRoster: atom([{ name: 'scout' }]),
    botSelectionKey: (bot: RosterRow) => bot.name
  }
})
vi.mock('./i18n', () => ({
  useBots: () => ({
    handback: {
      actionFailed: 'Could not update',
      cancel: 'Cancel',
      cancelMessage: 'Cancel that task.',
      continueMessage: 'I am done.',
      done: "I'm done",
      elsewhere: 'Another viewer is in control',
      inControl: 'You have control',
      needsYou: 'Needs you',
      openComputer: 'Open computer',
      resolved: 'Handed back',
      sendFailed: (name: string) => `Could not message ${name}`
    }
  })
}))
vi.mock('./screen-connection', async importActual => ({
  ...(await importActual<typeof ScreenConnection>()),
  displayRequest: vi.fn(),
  isEventForBotScreen: () => false
}))

import { HandbackCard } from './handback-card'
import { displayRequest } from './screen-connection'
import { $screenState, $takeoverIntents, setScreenLease, setScreenViewer } from './screen-state'

const bot: RosterRow = { name: 'scout' }
const ASK_AT = 42.5
const result = { reason: 'Sign in to Example to continue', requested_at: ASK_AT, status: 'waiting_for_person', success: true }

const lease = (patch: Partial<DisplayLease> = {}): DisplayLease => ({
  ask: result.reason,
  ask_at: ASK_AT,
  epoch: 1,
  holder: 'agent',
  since: 1,
  viewer_hash: null,
  ...patch
})

const status = (l: DisplayLease) => ({
  display: ':20',
  geometry: '1x1',
  installed: true,
  lease: l,
  profile: 'scout',
  profile_key: '/h',
  running: true,
  supported: true
})

const calls = (method: string) => vi.mocked(displayRequest).mock.calls.filter(([, m]) => m === method)

function mount(initial: DisplayLease, viewerHash?: string) {
  vi.mocked(displayRequest).mockImplementation(async (_bot, method) =>
    method === 'display.status'
      ? status(initial)
      : method === 'display.lease.resolve'
        ? { lease: lease({ ask: '', ask_at: 0, epoch: 9 }) }
        : { lease: lease({ epoch: 8 }) }
  )
  setScreenLease(bot, initial)

  if (viewerHash) {
    setScreenViewer(bot, { hash: viewerHash, id: 'my-viewer' })
  }

  return render(
    <HandbackCard
      args={{ reason: result.reason }}
      fallback={<span>fallback row</span> as ReactNode}
      result={result}
      sessionId="stored-1"
      toolCallId="call-1"
      toolName="request_handback"
    />
  )
}

beforeEach(() => {
  $screenState.set({})
  $takeoverIntents.set({})
  vi.mocked(displayRequest).mockReset()
  submit.mockReset().mockReturnValue(true)
  notify.mockReset()
  openBotScreen.mockReset()
})

it('shows the reason with Open computer, I am done and Cancel while the ask is pending', async () => {
  const view = mount(lease())
  expect(view.getByText('Sign in to Example to continue')).toBeTruthy()
  expect(view.getByText('Open computer')).toBeTruthy()
  expect(view.getByText("I'm done")).toBeTruthy()
  expect(view.getByText('Cancel')).toBeTruthy()
  await waitFor(() => expect(calls('display.status').length).toBeGreaterThanOrEqual(1))
})

it('Open computer raises a takeover intent for the bot and opens its Screen pane', async () => {
  const view = mount(lease())
  fireEvent.click(view.getByText('Open computer'))
  expect($takeoverIntents.get().scout?.reason).toBe('Sign in to Example to continue')
  expect(openBotScreen).toHaveBeenCalledTimes(1)
  expect(openBotScreen.mock.calls[0][0]).toEqual(bot)
  await waitFor(() => expect(calls('display.status').length).toBeGreaterThanOrEqual(1))
})

it('I am done releases the lease I hold, ends the ask and sends the continue message', async () => {
  const view = mount(lease({ epoch: 3, holder: 'human', viewer_hash: 'abc' }), 'abc')
  expect(view.getByText('You have control')).toBeTruthy()
  expect(view.queryByText('Open computer')).toBeNull()
  fireEvent.click(view.getByText("I'm done"))
  await waitFor(() => expect(submit).toHaveBeenCalledWith('stored-1', 'I am done.'))
  expect(calls('display.lease.release')[0][2]).toEqual({ viewer_id: 'my-viewer' })
  expect(calls('display.lease.resolve')[0][2]).toEqual({ ask_at: ASK_AT })
  await waitFor(() => expect(view.getByText('Handed back')).toBeTruthy())
  expect(view.queryByText("I'm done")).toBeNull()
})

it('Cancel ends the ask and tells the bot to stop that task, without taking the lease', async () => {
  const view = mount(lease())
  fireEvent.click(view.getByText('Cancel'))
  await waitFor(() => expect(submit).toHaveBeenCalledWith('stored-1', 'Cancel that task.'))
  expect(calls('display.lease.resolve')).toHaveLength(1)
  expect(calls('display.lease.release')).toHaveLength(0)
  expect(calls('display.lease.acquire')).toHaveLength(0)
})

it('keeps the card pending and says so when the lease is held by another viewer', async () => {
  const view = mount(lease({ holder: 'human', viewer_hash: 'zzz' }), 'abc')
  expect(view.getByText('Another viewer is in control')).toBeTruthy()
  expect(view.queryByText("I'm done")).toBeNull()
  fireEvent.click(view.getByText('Open computer'))
  expect($takeoverIntents.get()).toEqual({})
  expect(openBotScreen).toHaveBeenCalledTimes(1)
  await waitFor(() => expect(calls('display.status').length).toBeGreaterThanOrEqual(1))
})

it('leaves the ask pending and reports the failure when ending it fails', async () => {
  const view = mount(lease())
  vi.mocked(displayRequest).mockImplementation(async (_bot, method) => {
    if (method === 'display.lease.resolve') {
      throw new Error('gateway gone')
    }

    return status(lease())
  })
  fireEvent.click(view.getByText("I'm done"))
  await waitFor(() => expect(notify).toHaveBeenCalledWith({ kind: 'error', message: 'Could not update' }))
  expect(submit).not.toHaveBeenCalled()
  expect(view.getByText("I'm done")).toBeTruthy()
})

it('tells the owner when the continue message could not be sent', async () => {
  submit.mockReturnValue(false)
  const view = mount(lease())
  fireEvent.click(view.getByText("I'm done"))
  await waitFor(() => expect(notify).toHaveBeenCalledWith({ kind: 'error', message: 'Could not message scout' }))
})

it('renders an older, settled request as handed back with no actions', async () => {
  const view = mount(lease({ ask: '', ask_at: 0 }))
  expect(view.getByText('Handed back')).toBeTruthy()
  expect(view.queryByText('Open computer')).toBeNull()
  await waitFor(() => expect(calls('display.status').length).toBeGreaterThanOrEqual(1))
})
