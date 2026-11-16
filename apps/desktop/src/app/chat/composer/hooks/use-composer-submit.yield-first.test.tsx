import { act, cleanup, renderHook } from '@testing-library/react'
import type { PropsWithChildren } from 'react'
import { afterEach, describe, expect, it, vi } from 'vitest'

import { PaneVisibleContext } from '@/components/pane-shell/pane-visibility'
import type { ComposerAttachment } from '@/store/composer'
import { clearQueuedPrompts, getQueuedPrompts } from '@/store/composer-queue'

import { requestComposerSubmit } from '../focus'
import { ComposerScopeProvider, ComposerSurfaceProvider, MAIN_COMPOSER_SCOPE } from '../scope'
import type { ChatBarProps } from '../types'

import { useComposerSubmit } from './use-composer-submit'

const SESSION_KEY = 'yield-first-stored'
const SURFACE = 'yield-first-surface'

function renderSubmit({
  attachments = [],
  busy = true,
  busyInputMode = 'interrupt',
  text,
  yieldFirst
}: {
  attachments?: ComposerAttachment[]
  busy?: boolean
  busyInputMode?: 'interrupt' | 'queue' | 'steer' | null
  text: string
  yieldFirst: boolean
}) {
  const draftRef = { current: text }
  const editor = window.document.createElement('div')
  editor.dataset.slot = 'composer-rich-input'
  editor.textContent = text
  const onSteer = vi.fn(async () => true)
  const onSteerHidden = vi.fn(async () => true)
  const onSubmit = vi.fn<ChatBarProps['onSubmit']>(async () => true)
  const onCancel = vi.fn()
  const queueCurrentDraft = vi.fn(() => true)

  const clearDraft = vi.fn(() => {
    draftRef.current = ''
    editor.textContent = ''
  })

  const Wrapper = ({ children }: PropsWithChildren) => (
    <ComposerScopeProvider value={MAIN_COMPOSER_SCOPE}>
      <ComposerSurfaceProvider value={SURFACE}>
        <PaneVisibleContext.Provider value>
          <div data-composer-surface-id={SURFACE} data-composer-target="main">
            {children}
          </div>
        </PaneVisibleContext.Provider>
      </ComposerSurfaceProvider>
    </ComposerScopeProvider>
  )

  const hook = renderHook(
    () =>
      useComposerSubmit({
        activeQueueSessionKey: SESSION_KEY,
        activeQueueSessionKeyRef: { current: SESSION_KEY },
        attachments,
        busy,
        busyInputMode,
        clearDraft,
        disabled: false,
        draftRef,
        draftScopeRef: { current: SESSION_KEY },
        drainNextQueued: vi.fn(async () => false),
        editorRef: { current: editor },
        exitQueuedEdit: vi.fn(() => false),
        focusInput: vi.fn(),
        inputDisabled: false,
        loadIntoComposer: vi.fn(),
        onCancel,
        onSteer,
        onSteerHidden,
        onSubmit,
        queueCurrentDraft,
        queueEdit: null,
        queuedPrompts: [],
        sessionId: 'yield-first-runtime',
        setComposerText: vi.fn(),
        stashAt: vi.fn(),
        yieldFirst
      }),
    { wrapper: Wrapper }
  )

  return { clearDraft, hook, onCancel, onSteer, onSteerHidden, onSubmit, queueCurrentDraft }
}

afterEach(() => {
  cleanup()
  clearQueuedPrompts(SESSION_KEY)
})

describe('Send while a turn runs in a yield-first chat', () => {
  it.each(['interrupt', 'steer', 'queue', null] as const)(
    'submits the text with prompt.submit and takes no steer, redirect or queue branch (policy %s)',
    async busyInputMode => {
      const h = renderSubmit({ busyInputMode, text: 'also what is the weather?', yieldFirst: true })

      await act(async () => h.hook.result.current.submitDraft())

      expect(h.onSubmit).toHaveBeenCalledExactlyOnceWith(
        'also what is the weather?',
        expect.objectContaining({ attachments: [], submission_id: expect.any(String) })
      )
      expect(h.onSubmit.mock.calls[0][1]).not.toHaveProperty('fromQueue')
      expect(h.onSteer).not.toHaveBeenCalled()
      expect(h.queueCurrentDraft).not.toHaveBeenCalled()
      expect(getQueuedPrompts(SESSION_KEY)).toEqual([])
      expect(h.clearDraft).toHaveBeenCalled()
    }
  )

  it('also sends attachments with the same single call', async () => {
    const image = { id: 'a1', kind: 'image', label: 'shot.png', path: '/tmp/shot.png' } as ComposerAttachment
    const h = renderSubmit({ attachments: [image], text: 'look at this', yieldFirst: true })

    await act(async () => h.hook.result.current.submitDraft())

    expect(h.onSubmit).toHaveBeenCalledExactlyOnceWith(
      'look at this',
      expect.objectContaining({ attachments: [image] })
    )
    expect(h.queueCurrentDraft).not.toHaveBeenCalled()
  })

  it('an empty composer still stops the turn', async () => {
    const h = renderSubmit({ text: '', yieldFirst: true })

    await act(async () => h.hook.result.current.submitDraft())

    expect(h.onCancel).toHaveBeenCalledOnce()
    expect(h.onSubmit).not.toHaveBeenCalled()
  })

  it('a visible request from a card click is submitted the same way; a hidden note still steers', async () => {
    const h = renderSubmit({ text: '', yieldFirst: true })

    await act(async () => {
      requestComposerSubmit('Yes, merge it.', { target: 'main' })
    })

    expect(h.onSubmit).toHaveBeenCalledExactlyOnceWith('Yes, merge it.', expect.objectContaining({ attachments: [] }))
    expect(h.onSteer).not.toHaveBeenCalled()

    await act(async () => {
      requestComposerSubmit('[setup] note', { target: 'main', displayKind: 'hidden' })
    })

    expect(h.onSteerHidden).toHaveBeenCalledExactlyOnceWith('[setup] note')
    expect(h.onSubmit).toHaveBeenCalledTimes(1)
  })
})

describe('Send while a turn runs in any other chat', () => {
  it('still follows the busy-input policy', async () => {
    const steering = renderSubmit({ busyInputMode: 'steer', text: 'nudge', yieldFirst: false })

    await act(async () => steering.hook.result.current.submitDraft())

    expect(steering.onSteer).toHaveBeenCalledExactlyOnceWith('nudge', 'steer')
    expect(steering.onSubmit).not.toHaveBeenCalled()

    const queueing = renderSubmit({ busyInputMode: 'queue', text: 'later', yieldFirst: false })

    await act(async () => queueing.hook.result.current.submitDraft())

    expect(queueing.queueCurrentDraft).toHaveBeenCalledOnce()
    expect(queueing.onSteer).not.toHaveBeenCalled()
    expect(queueing.onSubmit).not.toHaveBeenCalled()
  })
})
