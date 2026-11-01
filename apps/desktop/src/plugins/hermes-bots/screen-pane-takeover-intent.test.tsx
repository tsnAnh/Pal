import { act, render, waitFor } from '@testing-library/react'
import type { ReactNode } from 'react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'

import type { DisplayStatus } from './screen-connection'
import type * as ScreenConnection from './screen-connection'
import type { RosterRow } from './types'

const sockets = vi.hoisted(
  () =>
    [] as Array<{
      closeCodes: number[]
      closed: boolean
      close: (code?: number) => void
      serverClose: (code: number) => void
    }>
)

const rfbs = vi.hoisted(() => [] as Array<{ emit: (type: string, detail?: unknown) => void; viewOnly?: boolean }>)
const retention = vi.hoisted(() => ({ held: 0 }))

vi.mock('@hermes/plugin-sdk', async () => {
  const { useStore } = await import('@nanostores/react')
  const { onGatewayEvent } = await import('../../contrib/events')

  return {
    Button: ({ children, ...props }: React.ButtonHTMLAttributes<HTMLButtonElement>) => (
      <button {...props}>{children}</button>
    ),
    Codicon: () => null,
    GlyphSpinner: () => null,
    Tip: ({ children }: { children: ReactNode }) => <>{children}</>,
    EmptyState: () => null,
    useValue: useStore,
    host: {
      onEvent: onGatewayEvent,
      retainProfile: async () => {
        retention.held += 1

        return () => {
          retention.held -= 1
        }
      }
    }
  }
})
vi.mock('./routing', () => {
  const route = { connectionId: 'host-a', mode: 'remote', profile: 'default', targetProfile: 'default' }

  return { botConnectionRoute: () => route, resolveBotConnectionRoute: () => ({ status: 'resolved', route }) }
})
vi.mock('./data', () => ({ botSelectionKey: (bot: RosterRow) => bot.name }))
vi.mock('./teach-skill-controls', () => ({ TeachSkillBanner: () => null, TeachSkillControls: () => null }))
vi.mock('./i18n', () => ({
  useBots: () => ({
    screen: {
      title: 'Screen',
      controlTaken: 'Another viewer took control',
      youControl: 'You control',
      handBack: 'Hand back',
      takeOver: 'Take over',
      reconnect: 'Reconnect',
      streamLost: 'Stream lost',
      agentControls: 'Agent',
      otherControls: 'Other'
    }
  })
}))
vi.mock('./screen-connection', async importActual => ({
  // Real pure helpers (viewerHash / leaseHeldBy); only the gateway legs are faked.
  ...(await importActual<typeof ScreenConnection>()),
  displayRequest: vi.fn(),
  resolveScreenWsUrl: vi.fn(async () => 'ws://localhost/api/display/ws'),
  isEventForBotScreen: () => false
}))
vi.mock('@novnc/novnc', () => ({
  default: class {
    private listeners = new Map<string, Array<(event: { detail?: unknown }) => void>>()
    viewOnly = true
    constructor(
      _target: HTMLElement,
      private socket: { close: () => void }
    ) {
      rfbs.push(this)
    }
    emit(type: string, detail?: unknown) {
      for (const listener of this.listeners.get(type) ?? []) {
        listener({ detail })
      }
    }
    addEventListener(type: string, callback: (event: { detail?: unknown }) => void) {
      this.listeners.set(type, [...(this.listeners.get(type) ?? []), callback])

      if (type === 'connect') {
        queueMicrotask(() => callback({}))
      }
    }
    // noVNC 1.7 disconnects its WebSocket without a close code.
    disconnect() {
      this.socket.close()
    }
    focus() {}
  }
}))

import { displayRequest } from './screen-connection'
import { BotScreenPane } from './screen-pane'
import { $screenState, $takeoverIntents, requestScreenTakeover } from './screen-state'

const bot: RosterRow = { name: 'default' }

const status: DisplayStatus = {
  profile: 'default',
  profile_key: '/home/hermes/.hermes',
  supported: true,
  installed: true,
  missing: [],
  running: true,
  pid: 42,
  display: ':20',
  socket: '/tmp/rfb.sock',
  geometry: '1440x900',
  install_command: null,
  lease: { holder: 'agent', viewer_id: null, viewer_hash: null, since: 1, reason: '', epoch: 1, ask: 'Sign in to Example', ask_at: 5 }
}

beforeEach(() => {
  $screenState.set({})
  $takeoverIntents.set({})
  sockets.length = 0
  rfbs.length = 0
  retention.held = 0
  vi.mocked(displayRequest)
    .mockReset()
    .mockResolvedValue({ ...status, ticket: 'test-ticket', viewer_id: 'this-viewer' })
  vi.stubGlobal(
    'WebSocket',
    class {
      closeCodes: number[] = []
      closed = false
      private onClose: Array<(event: { code: number }) => void> = []
      constructor() {
        sockets.push(this)
      }
      addEventListener(type: string, listener: (event: { code: number }) => void) {
        if (type === 'close') {
          this.onClose.push(listener)
        }
      }
      // The bridge closing us: the raw close frame reaches our listener, then noVNC
      // reports a statusless `disconnect` — the code is only on the socket event.
      serverClose(code: number) {
        this.closed = true

        for (const listener of this.onClose) {
          listener({ code })
        }
      }
      close(code?: number) {
        // Subsequent close calls cannot replace the frame already sent to the server.
        if (this.closed) {
          return
        }

        this.closed = true
        this.closeCodes.push(code ?? 1005)
      }
    }
  )
})

afterEach(() => vi.unstubAllGlobals())


const acquires = () =>
  vi.mocked(displayRequest).mock.calls.filter(([, method]) => method === 'display.lease.acquire')

const mountLive = async () => {
  const view = render(<BotScreenPane bot={bot} />)
  await waitFor(() => expect(sockets).toHaveLength(1))
  await act(async () => {})

  return view
}

it('Open computer takes the lease with the ask as the reason once the pane has its viewer', async () => {
  const view = await mountLive()
  expect(acquires()).toHaveLength(0)
  act(() => requestScreenTakeover(bot, 'Sign in to Example'))
  await waitFor(() => expect(acquires()).toHaveLength(1))
  expect(acquires()[0][2]).toEqual({ reason: 'Sign in to Example', viewer_id: 'this-viewer' })
  expect($takeoverIntents.get()).toEqual({})
  view.unmount()
})

it('picks up an intent that was raised before the pane mounted', async () => {
  requestScreenTakeover(bot, 'Enter the code')
  const view = await mountLive()
  await waitFor(() => expect(acquires()).toHaveLength(1))
  expect(acquires()[0][2]).toMatchObject({ reason: 'Enter the code' })
  view.unmount()
})

it('never steals the lease from another viewer: the intent is consumed and the pane only watches', async () => {
  vi.mocked(displayRequest).mockImplementation(async () => ({
    ...status,
    lease: { ...status.lease!, holder: 'human', viewer_hash: 'someone-else1' },
    ticket: 'test-ticket',
    viewer_id: 'this-viewer'
  }))
  const view = await mountLive()
  act(() => requestScreenTakeover(bot, 'Sign in to Example'))
  await waitFor(() => expect($takeoverIntents.get()).toEqual({}))
  expect(acquires()).toHaveLength(0)
  view.unmount()
})

it('drops an intent nobody consumed in time instead of taking control on a stale click', async () => {
  requestScreenTakeover(bot, 'Sign in to Example', Date.now() - 60_000)
  const view = await mountLive()
  await act(async () => {})
  expect(acquires()).toHaveLength(0)
  view.unmount()
})
