import { cleanup, render, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { type ChatPersona, setHandlePersonas } from '@/store/chat-persona'
import { $gateway } from '@/store/gateway'

import { agentAvatarCache, AgentGlyph } from './agent-glyph'

const persona: ChatPersona = {
  avatar: size => <span data-testid="persona-avatar">{size}</span>,
  name: 'Scribe'
}

const requests: string[] = []

beforeEach(() => {
  requests.length = 0

  for (const key of [...agentAvatarCache.keys()]) {
    agentAvatarCache.delete(key)
  }

  $gateway.set({
    request: async (method: string) => {
      requests.push(method)

      return { profiles: [] }
    }
  } as never)
})

afterEach(() => {
  cleanup()
  setHandlePersonas({})
  $gateway.set(null)
  vi.restoreAllMocks()
})

describe('AgentGlyph', () => {
  it('paints the matched bot persona without fetching an avatar', async () => {
    setHandlePersonas({ scribe: persona })

    const { findByTestId } = render(<AgentGlyph handle="Scribe" />)

    expect((await findByTestId('persona-avatar')).textContent).toBe('16')
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(requests).toEqual([])
  })

  it('falls back to the robot glyph and the avatar lookup for an unknown handle', async () => {
    const { container } = render(<AgentGlyph handle="stranger" />)

    await waitFor(() => expect(requests).toEqual(['profiles.list']))
    expect(container.textContent).toBe('🤖')
  })

  it('does not treat object prototype names as persona handles', async () => {
    setHandlePersonas({ scribe: persona })

    const { container } = render(<AgentGlyph handle="constructor" />)

    await waitFor(() => expect(requests).toEqual(['profiles.list']))
    expect(container.textContent).toBe('🤖')
  })
})
