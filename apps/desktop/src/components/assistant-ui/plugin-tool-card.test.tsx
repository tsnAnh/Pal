import { render } from '@testing-library/react'
import type { ComponentProps } from 'react'
import { afterEach, expect, it, vi } from 'vitest'

import { registry } from '@/contrib'
import { TOOL_CARD_AREA } from '@/lib/tool-card-renderers'

import { PluginToolCard } from './plugin-tool-card'

vi.mock('@/app/chat/session-view', async () => {
  const { atom } = await import('nanostores')

  return { useSessionView: () => ({ $runtimeId: atom('runtime-1'), $storedId: atom('stored-1') }) }
})
vi.mock('@/components/assistant-ui/tool/fallback', () => ({ ToolFallback: () => <span>built-in row</span> }))

const props = (patch: Record<string, unknown> = {}) =>
  ({
    args: { reason: 'Sign in' },
    isError: false,
    result: '{"success":true}',
    toolCallId: 'call-1',
    toolName: 'request_handback',
    ...patch
  }) as unknown as ComponentProps<typeof PluginToolCard>

const disposers: Array<() => void> = []

const claim = (render: (p: { fallback: unknown; sessionId: null | string }) => unknown) =>
  disposers.push(
    registry.register({
      area: TOOL_CARD_AREA,
      data: { render, tools: ['request_handback'] },
      id: `card-${disposers.length}`
    })
  )

afterEach(() => {
  while (disposers.length) {
    disposers.pop()?.()
  }
})

it('keeps the built-in row when no plugin claims the tool', () => {
  expect(render(<PluginToolCard {...props()} />).getByText('built-in row')).toBeTruthy()
})

it('draws the claiming plugin card for a finished call, with the chat session id', () => {
  claim(({ sessionId }) => <span>plugin card {sessionId}</span>)
  expect(render(<PluginToolCard {...props()} />).getByText('plugin card stored-1')).toBeTruthy()
})

it('keeps the built-in row while the call runs and when it failed', () => {
  claim(() => <span>plugin card</span>)
  const running = render(<PluginToolCard {...props({ result: undefined })} />)
  expect(running.getByText('built-in row')).toBeTruthy()
  running.unmount()
  expect(render(<PluginToolCard {...props({ isError: true })} />).getByText('built-in row')).toBeTruthy()
})

it('falls back to the built-in row when the plugin declines or throws', () => {
  claim(() => null)
  const declined = render(<PluginToolCard {...props()} />)
  expect(declined.getByText('built-in row')).toBeTruthy()
  declined.unmount()
  disposers.pop()?.()
  vi.spyOn(console, 'error').mockImplementation(() => undefined)
  claim(() => {
    throw new Error('boom')
  })
  expect(render(<PluginToolCard {...props()} />).getByText('built-in row')).toBeTruthy()
})
