import { act, cleanup, renderHook } from '@testing-library/react'
import { useRef } from 'react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { PRIMARY_SESSION_VIEW } from '@/app/chat/session-view'
import { en } from '@/i18n/en'
import { chatMessageText } from '@/lib/chat-messages'
import { getQueuedPrompts } from '@/store/composer-queue'
import {
  $connection,
  setActiveSessionId,
  setAwaitingResponse,
  setBusy,
  setMessages,
  setSelectedStoredSessionId,
  setSessions
} from '@/store/session'
import { $botChatSessionIds, clearAllSessionStates } from '@/store/session-states'
import { makeSessionInfo } from '@/test/session-info'

import { useSessionStateCache } from '../use-session-state-cache'

import { useSubmitPrompt } from './submit'

const SID = 'yield-first-submit'
const INPUT = 'also what is the weather in Hanoi?'

function mount(status: string) {
  const request = vi.fn(async (_method: string, params: Record<string, unknown>) => ({
    admission_id: params.submission_id,
    submission_id: params.submission_id,
    session_id: SID,
    status
  }))

  const hook = renderHook(() => {
    const busyRef = useRef(false)

    const cache = useSessionStateCache({
      activeSessionId: SID,
      selectedStoredSessionId: SID,
      busyRef,
      setMessages,
      setBusy,
      setAwaitingResponse
    })

    const submit = useSubmitPrompt({
      ...cache,
      busyRef,
      copy: en.desktop,
      createBackendSessionForSend: async () => null,
      getRoutedStoredSessionId: () => SID,
      getRouteToken: () => `/${SID}`,
      requestGateway: request as Parameters<typeof useSubmitPrompt>[0]['requestGateway'],
      resumeStoredSession: async () => undefined,
      syncAttachmentsForSubmit: async (sessionId, attachments) => ({ sessionId, attachments })
    })

    return { cache, submit }
  })

  act(() => {
    hook.result.current.cache.updateSessionState(SID, state => state, SID)
  })

  const runTurn = () =>
    act(() => {
      hook.result.current.cache.updateSessionState(
        SID,
        state => ({ ...state, busy: true, awaitingResponse: true, turnLive: true, turnStartedAt: 1234 }),
        SID
      )
    })

  return { hook, request, runTurn }
}

beforeEach(() => {
  window.localStorage.clear()
  clearAllSessionStates()
  $botChatSessionIds.set(new Set())
  setMessages([])
  setBusy(false)
  setAwaitingResponse(false)
  setActiveSessionId(SID)
  setSelectedStoredSessionId(SID)
  setSessions([makeSessionInfo({ id: SID, source: 'gui', message_count: 0 })])
  $connection.set({
    mode: 'local',
    connectionId: 'local',
    profile: 'default',
    baseUrl: 'http://127.0.0.1:1',
    wsUrl: 'ws://127.0.0.1:1/api/ws?native_dial=1',
    token: '',
    logs: [],
    isFullscreen: false,
    nativeOverlayWidth: 0,
    windowButtonPosition: null
  })
})

afterEach(() => {
  cleanup()
  clearAllSessionStates()
  $botChatSessionIds.set(new Set())
  setMessages([])
  setBusy(false)
  setAwaitingResponse(false)
  setActiveSessionId(null)
  setSelectedStoredSessionId(null)
  setSessions([])
  $connection.set(null)
  vi.restoreAllMocks()
})

describe('a submit receipt that says the owner message was delivered', () => {
  it.each(['steered', 'turn'])('%s is accepted: no queued chip and the turn stays live', async status => {
    const { hook, request, runTurn } = mount(status)
    runTurn()

    await act(async () => {
      expect(await hook.result.current.submit(INPUT)).toBe(true)
    })

    expect(request).toHaveBeenCalledTimes(1)
    expect(getQueuedPrompts(SID)).toEqual([])
    expect(PRIMARY_SESSION_VIEW.$busy.get()).toBe(true)
    expect(hook.result.current.cache.sessionStateByRuntimeIdRef.current.get(SID)).toMatchObject({
      busy: true,
      turnLive: true
    })
  })

  it('turn on an idle chat keeps the optimistic bubble the turn adopts', async () => {
    const { hook } = mount('turn')

    await act(async () => {
      expect(await hook.result.current.submit(INPUT)).toBe(true)
    })

    expect(PRIMARY_SESSION_VIEW.$messages.get().map(chatMessageText)).toEqual([INPUT])
    expect(PRIMARY_SESSION_VIEW.$busy.get()).toBe(true)
  })
})

describe('what a busy submit tells the gateway', () => {
  it('a bot chat sends the owner message as a plain submit, not as a run-after request', async () => {
    $botChatSessionIds.set(new Set([SID]))
    const { hook, request, runTurn } = mount('steered')
    runTurn()

    await act(async () => {
      expect(await hook.result.current.submit(INPUT)).toBe(true)
    })

    expect(request).toHaveBeenCalledWith('prompt.submit', expect.objectContaining({ text: INPUT }), expect.anything())
    expect(request.mock.calls[0][1]).not.toHaveProperty('queued')
  })

  it('any other chat still asks to run after the live turn', async () => {
    const { hook, request, runTurn } = mount('queued')
    runTurn()

    await act(async () => {
      expect(await hook.result.current.submit(INPUT)).toBe(true)
    })

    expect(request.mock.calls[0][1]).toMatchObject({ queued: true })
  })

  it('a bot chat draining its own earlier queue entry still asks to run after', async () => {
    $botChatSessionIds.set(new Set([SID]))
    const { hook, request, runTurn } = mount('queued')
    runTurn()

    await act(async () => {
      expect(await hook.result.current.submit(INPUT, { fromQueue: true })).toBe(true)
    })

    expect(request.mock.calls[0][1]).toMatchObject({ queued: true })
  })
})
