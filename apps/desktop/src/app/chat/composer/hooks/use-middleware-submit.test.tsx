import { renderHook } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'

import { registry } from '@/contrib/registry'

import { COMPOSER_AREAS, type ComposerMiddleware } from '../contrib'
import type { ChatBarProps } from '../types'

import { useMiddlewareSubmit } from './use-middleware-submit'

const disposers: Array<() => void> = []

afterEach(() => {
  disposers.splice(0).forEach(dispose => dispose())
})

describe('useMiddlewareSubmit', () => {
  it('sends the typed text as written and the middleware note as model-only turn context', async () => {
    disposers.push(
      registry.register({
        id: 'notes',
        area: COMPOSER_AREAS.middleware,
        data: { handler: draft => ({ ...draft, turnContext: 'resolved: @bot' }) } satisfies ComposerMiddleware
      })
    )

    const onSubmit = vi.fn<ChatBarProps['onSubmit']>(async () => true)
    const { result } = renderHook(() => useMiddlewareSubmit(onSubmit))

    expect(await result.current.onSubmit('ask @bot to say hi', { fromQueue: true })).toBe(true)
    expect(onSubmit).toHaveBeenCalledWith('ask @bot to say hi', {
      attachments: undefined,
      fromQueue: true,
      turnContext: 'resolved: @bot'
    })
  })

  it('adds no turn context when no middleware supplies one', async () => {
    const onSubmit = vi.fn<ChatBarProps['onSubmit']>(async () => true)
    const { result } = renderHook(() => useMiddlewareSubmit(onSubmit))

    await result.current.onSubmit('plain', undefined)
    expect(onSubmit.mock.calls[0]?.[1]).not.toHaveProperty('turnContext')
  })
})
