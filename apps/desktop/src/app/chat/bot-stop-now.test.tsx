import { cleanup, fireEvent, render, renderHook, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'

import { notifyError } from '@/store/notifications'

import { BotStopNow, useChatHalt } from './bot-stop-now'

vi.mock('@/store/notifications', () => ({ notifyError: vi.fn() }))
vi.mock('@/store/composer-queue', () => ({ parkQueuedPrompts: vi.fn() }))
vi.mock('@/app/session/hooks/use-session-actions/utils', () => ({ resolveSessionProfile: async () => undefined }))

afterEach(() => {
  cleanup()
  vi.mocked(notifyError).mockReset()
})

it('stops the bot chat immediately when pressed', () => {
  const onStop = vi.fn()
  render(<BotStopNow label="Stop now" onStop={onStop} />)

  fireEvent.click(screen.getByRole('button', { name: 'Stop now' }))

  expect(onStop).toHaveBeenCalledTimes(1)
})

it('Stop now interrupts the turn, then ends the session background work and handoffs', async () => {
  const order: string[] = []

  const onCancel = vi.fn(async () => {
    order.push('interrupt')
  })

  const request = vi.fn(async (method: string) => {
    order.push(method)
  }) as never

  const { result } = renderHook(() =>
    useChatHalt({ activeSessionId: 'live-1', gateway: null, onCancel, queueSessionKey: 'stored-1', request })
  )

  await result.current.stopNow()

  expect(order).toEqual(['interrupt', 'process.stop'])
  expect(request).toHaveBeenCalledWith('process.stop', { session_id: 'live-1' })
})

it('plain halt interrupts only and leaves background work alone', async () => {
  const onCancel = vi.fn()
  const request = vi.fn() as never

  const { result } = renderHook(() =>
    useChatHalt({ activeSessionId: 'live-1', gateway: null, onCancel, queueSessionKey: 'stored-1', request })
  )

  await result.current.haltRun()

  expect(onCancel).toHaveBeenCalledTimes(1)
  expect(request).not.toHaveBeenCalled()
})

it('reports a failed background stop instead of hiding it', async () => {
  const request = vi.fn(async () => {
    throw new Error('owner unreachable')
  }) as never

  const { result } = renderHook(() =>
    useChatHalt({ activeSessionId: 'live-1', gateway: null, onCancel: vi.fn(), queueSessionKey: 'stored-1', request })
  )

  await result.current.stopNow()

  expect(notifyError).toHaveBeenCalledTimes(1)
})

it('still ends background work and reports when the interrupt rejects', async () => {
  const onCancel = vi.fn(async () => {
    throw new Error('interrupt failed')
  })

  const request = vi.fn(async () => undefined) as never

  const { result } = renderHook(() =>
    useChatHalt({ activeSessionId: 'live-1', gateway: null, onCancel, queueSessionKey: 'stored-1', request })
  )

  await result.current.stopNow()

  expect(request).toHaveBeenCalledWith('process.stop', { session_id: 'live-1' })
  expect(notifyError).toHaveBeenCalledTimes(1)
})

it('recovers a reaped runtime for the stop by resuming the stored session once', async () => {
  const request = vi.fn(async (method: string, params?: Record<string, unknown>) => {
    if (method === 'process.stop' && params?.session_id === 'dead-1') {
      throw new Error('session not found')
    }

    if (method === 'session.resume') {
      return { session_id: 'live-2' }
    }

    return undefined
  }) as never

  const { result } = renderHook(() =>
    useChatHalt({ activeSessionId: 'dead-1', gateway: null, onCancel: vi.fn(), queueSessionKey: 'stored-1', request })
  )

  await result.current.stopNow()

  expect(request).toHaveBeenCalledWith('process.stop', { session_id: 'live-2' })
  expect(notifyError).not.toHaveBeenCalled()
})
