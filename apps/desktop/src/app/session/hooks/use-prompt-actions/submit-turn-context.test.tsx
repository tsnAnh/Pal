import { act, cleanup, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { en } from '@/i18n/en'
import { createClientSessionState } from '@/lib/chat-runtime'
import { $activeGatewayProfile } from '@/store/profile'
import { $connection, $sessions } from '@/store/session'
import { $sessionStates } from '@/store/session-states'

import { useSubmitPrompt } from './submit'
import type { GatewayRequest, SubmitTextOptions } from './utils'

vi.mock('@/store/gateway', async original => ({
  ...(await original<Record<string, unknown>>()),
  retainGatewayForSessionTurn: vi.fn(async () => () => undefined)
}))

beforeEach(() => {
  window.localStorage.clear()
  $sessions.set([])
  $sessionStates.set({})
  $connection.set(null)
  $activeGatewayProfile.set('default')
})

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

type ClientSessionState = ReturnType<typeof createClientSessionState>
type Params = Record<string, unknown>

async function send(text: string, options: SubmitTextOptions, answer: (params: Params) => unknown) {
  let state: ClientSessionState = createClientSessionState()
  const submits: Params[] = []

  const requestGateway = vi.fn(async (method: string, params?: Params) => {
    if (method !== 'prompt.submit') {
      return {} as never
    }

    submits.push(params!)

    return (await answer(params!)) as never
  })

  const deps = {
    activeSessionIdRef: { current: 'runtime-a' as string | null },
    selectedStoredSessionIdRef: { current: 'stored-a' as string | null },
    busyRef: { current: false },
    copy: en.desktop,
    createBackendSessionForSend: vi.fn(async () => null),
    getRoutedStoredSessionId: () => null,
    getRuntimeIdForStoredSession: () => 'runtime-a',
    getRouteToken: () => 'same-route',
    requestGateway: requestGateway as GatewayRequest,
    runtimeIdByStoredSessionIdRef: { current: new Map([['stored-a', 'runtime-a']]) },
    resumeStoredSession: vi.fn(),
    syncAttachmentsForSubmit: vi.fn(async (sessionId: string) => ({ sessionId, attachments: [] })),
    updateSessionState: vi.fn((_sid: string, updater: (s: ClientSessionState) => ClientSessionState) => {
      state = updater(state)

      return state
    })
  }

  const { result } = renderHook(() => useSubmitPrompt(deps as never))
  let accepted = false

  await act(async () => {
    accepted = await result.current(text, options)
  })

  return { accepted, state, submits }
}

const started = (params: Params) => ({ admission_id: params.submission_id, session_id: 'runtime-a', status: 'started' })

const refusal = (key: string) =>
  Object.assign(
    new Error(`invalid params for prompt.submit: ${key}: Extra inputs are not permitted — the client and the Hermes backend are out of sync`),
    { code: 4000 }
  )

describe('turn context on prompt.submit', () => {
  it('goes beside the typed text and never into it or the sender bubble', async () => {
    const { accepted, state, submits } = await send(
      'ask @bot to say hi',
      { submission_id: 'sub-1', turnContext: '[@bot = agent profile "bot"]' },
      started
    )

    expect(accepted).toBe(true)
    expect(submits).toHaveLength(1)
    expect(submits[0]).toMatchObject({ text: 'ask @bot to say hi', turn_context: '[@bot = agent profile "bot"]' })
    expect(JSON.stringify(state.messages)).not.toContain('agent profile')
  })

  it('is left off a send that has none', async () => {
    const { submits } = await send('no tags', { submission_id: 'sub-2' }, started)

    expect(submits[0]).not.toHaveProperty('turn_context')
  })

  it('returns to the text of a backend that predates it, keeping the submission identity', async () => {
    const { accepted, submits } = await send('ask @bot', { submission_id: 'sub-3', turnContext: 'NOTE' }, params => {
      if ('turn_context' in params) {
        throw refusal('turn_context')
      }

      return started(params)
    })

    expect(accepted).toBe(true)
    expect(submits).toHaveLength(2)
    expect(submits[1]).not.toHaveProperty('turn_context')
    expect(submits[1]).toMatchObject({ text: 'ask @bot\n\nNOTE', submission_id: 'sub-3' })
  })

  it('returns to the text on the identityless retry of a backend that predates both', async () => {
    const { accepted, submits } = await send('ask @bot', { submission_id: 'sub-4', turnContext: 'NOTE' }, params => {
      if ('submission_id' in params) {
        throw refusal('submission_id')
      }

      return { session_id: 'runtime-a', status: 'streaming' }
    })

    expect(accepted).toBe(true)
    expect(submits[1]).toMatchObject({ text: 'ask @bot\n\nNOTE' })
    expect(submits[1]).not.toHaveProperty('turn_context')
    expect(submits[1]).not.toHaveProperty('submission_id')
  })
})
