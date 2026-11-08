import type * as HermesSdk from '@hermes/plugin-sdk'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { atom } from 'nanostores'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { translateBotsIn } from './i18n-test-helper'

const { requestProfile, gateway, connectionId } = await vi.hoisted(async () => {
  const { atom: make } = await import('nanostores')

  return {
    requestProfile: vi.fn(),
    gateway: make<string>('closed'),
    connectionId: make<null | string>('local')
  }
})

vi.mock('@hermes/plugin-sdk', async importOriginal => {
  const sdk = await importOriginal<typeof HermesSdk>()

  return {
    ...sdk,
    host: {
      ...sdk.host,
      requestProfile,
      state: { ...sdk.host.state, connectionId, gateway, profile: atom('default') }
    },
    usePluginI18n: () => translateBotsIn('en')
  }
})

import {
  $canonicalGroupBindings,
  $canonicalGroupLink,
  refreshGatewayGroupRooms,
  useGatewayGroupRooms
} from './canonical-group-registry'
import { useBots } from './i18n'
import { GatewayRetryButton, GatewayUnreachableNotice } from './roster-pane-toolbar'

const RAW = 'Hermes gateway is not connected'
const TITLE = "Can't reach Hermes"
let reachable = false

class RpcError extends Error {
  constructor(
    message: string,
    readonly code: number
  ) {
    super(message)
  }
}

function GatewayRooms() {
  const rooms = useGatewayGroupRooms()

  return (
    <>
      <button onClick={refreshGatewayGroupRooms} type="button">
        Refresh gateway groups
      </button>
      {rooms.map(room => (
        <span key={room.key}>{room.name}</span>
      ))}
    </>
  )
}

function Harness() {
  const b = useBots()

  return (
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <GatewayRetryButton b={b} />
      <GatewayUnreachableNotice b={b} />
      <GatewayRooms />
    </QueryClientProvider>
  )
}

const room = { room_id: 'r1', name: 'Team', members: [] }

function answer(method: string, listing: () => unknown) {
  return method === 'groups.capabilities' ? { driver: true } : listing()
}

beforeEach(() => {
  reachable = false
  gateway.set('closed')
  connectionId.set('local')
  requestProfile.mockImplementation(async (_route: unknown, method: string) => {
    if (!reachable) {
      throw new Error(RAW)
    }

    return answer(method, () => ({ rooms: [], next_offset: null }))
  })
})

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  $canonicalGroupBindings.set({})
  $canonicalGroupLink.set('ok')
})

async function settled() {
  await waitFor(() => expect(requestProfile).toHaveBeenCalled())
  await new Promise(resolve => setTimeout(resolve, 20))
}

it('an unreachable gateway shows a calm notice and a Retry button, never the raw error', async () => {
  render(<Harness />)

  expect(await screen.findByText(TITLE)).toBeTruthy()
  expect(screen.getByText('Reconnecting automatically…')).toBeTruthy()
  expect(screen.getByRole('button', { name: 'Retry' })).toBeTruthy()
  expect(screen.queryByText(RAW)).toBeNull()
  expect(screen.queryByRole('alert')).toBeNull()

  reachable = true
  gateway.set('open')

  await waitFor(() => expect(requestProfile).toHaveBeenCalled())
  await waitFor(() => expect(screen.queryByText(TITLE)).toBeNull())
  expect(screen.queryByRole('button', { name: 'Retry' })).toBeNull()
})

it('Retry re-reads the groups of an open gateway that dropped a request', async () => {
  gateway.set('open')
  render(<Harness />)

  expect(await screen.findByText(TITLE)).toBeTruthy()

  const calls = requestProfile.mock.calls.length
  reachable = true
  fireEvent.click(screen.getByRole('button', { name: 'Retry' }))

  await waitFor(() => expect(requestProfile.mock.calls.length).toBeGreaterThan(calls))
  await waitFor(() => expect(screen.queryByText(TITLE)).toBeNull())
})

describe('on a connected gateway a groups.list failure is not an unreachable gateway', () => {
  beforeEach(() => gateway.set('open'))

  it.each([
    ['method not found', () => new RpcError('Method not found', -32601)],
    ['method not found without a code', () => new Error('unknown method: groups.list')],
    ['an RPC error', () => new RpcError('internal error', -32000)],
    ['a bad pagination cursor', () => new Error('Invalid canonical group pagination cursor')]
  ])('shows no banner for %s', async (_label, failure) => {
    requestProfile.mockImplementation(async (_route: unknown, method: string) =>
      answer(method, () => {
        throw failure()
      })
    )
    render(<Harness />)
    await settled()

    expect(screen.queryByText(TITLE)).toBeNull()
    expect(screen.queryByRole('button', { name: 'Retry' })).toBeNull()
    expect($canonicalGroupLink.get()).toBe('ok')
  })

  it('shows no banner for a gateway that has no capabilities method either', async () => {
    requestProfile.mockRejectedValue(new RpcError('Method not found', -32601))
    render(<Harness />)
    await settled()

    expect(screen.queryByText(TITLE)).toBeNull()
  })

  it('shows no banner without a connection id', async () => {
    connectionId.set(null)
    render(<Harness />)
    await new Promise(resolve => setTimeout(resolve, 20))

    expect(screen.queryByText(TITLE)).toBeNull()
    expect($canonicalGroupLink.get()).toBe('ok')
  })

  it('keeps the rooms already listed when a refresh fails for a non-transport reason', async () => {
    let failing = false

    requestProfile.mockImplementation(async (_route: unknown, method: string) =>
      answer(method, () => {
        if (failing) {
          throw new RpcError('internal error', -32000)
        }

        return { rooms: [room], next_offset: null }
      })
    )
    render(<Harness />)
    expect(await screen.findByText('Team')).toBeTruthy()

    failing = true
    fireEvent.click(screen.getByRole('button', { name: 'Refresh gateway groups' }))
    await waitFor(() => expect(requestProfile.mock.calls.length).toBeGreaterThan(2))
    await new Promise(resolve => setTimeout(resolve, 20))

    expect(screen.getByText('Team')).toBeTruthy()
    expect(screen.queryByText(TITLE)).toBeNull()
  })

  it('still reports a dropped transport as unreachable', async () => {
    requestProfile.mockRejectedValue(new Error(RAW))
    render(<Harness />)

    expect(await screen.findByText(TITLE)).toBeTruthy()
  })
})

it('reports unreachable when the gateway is not open, whatever the error says', async () => {
  requestProfile.mockRejectedValue(new RpcError('internal error', -32000))
  render(<Harness />)

  expect(await screen.findByText(TITLE)).toBeTruthy()
})
