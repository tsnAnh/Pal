import { type ThreadMessage } from '@assistant-ui/react'
import { cleanup, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'

const text = vi.hoisted(() => ({ value: '' }))

vi.mock('@assistant-ui/react', () => ({
  MessagePrimitive: {
    Root: ({ children, ...props }: Record<string, unknown>) => <div {...props}>{children as never}</div>
  },
  useAuiState: (select: (state: unknown) => unknown) =>
    select({
      message: { content: [{ text: text.value, type: 'text' }], metadata: { custom: {} } } as Partial<ThreadMessage>
    })
}))

vi.mock('@/components/assistant-ui/thread/timeline-timestamp', () => ({ MessageTimelineTimestamp: () => null }))
vi.mock('@/components/assistant-ui/markdown-text', () => ({ MarkdownTextContent: () => null }))

import { SystemMessage } from './system-message'

describe('SystemMessage voice chat card', () => {
  afterEach(cleanup)

  it('renders the stored label as a card without the storage prefix', () => {
    text.value = 'voice-chat:Voice chat · 2:31'

    const { container } = render(<SystemMessage />)

    expect(screen.getByText('Voice chat · 2:31')).toBeTruthy()
    expect(container.querySelector('[data-slot="voice-call-card"]')).not.toBeNull()
    expect(container.textContent).not.toContain('voice-chat:')
  })

  it('leaves ordinary system text as a plain notice', () => {
    text.value = 'context compressed'

    const { container } = render(<SystemMessage />)

    expect(container.querySelector('[data-slot="voice-call-card"]')).toBeNull()
    expect(screen.getByText('context compressed')).toBeTruthy()
  })
})
