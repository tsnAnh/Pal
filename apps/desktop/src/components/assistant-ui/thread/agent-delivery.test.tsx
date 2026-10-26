import { cleanup, fireEvent, render } from '@testing-library/react'
import type { ComponentProps, ReactNode } from 'react'
import { afterEach, describe, expect, it } from 'vitest'

import { toChatMessages } from '@/lib/chat-messages'
import { toRuntimeMessage } from '@/lib/chat-runtime'
import { type ChatPersona, ChatPersonaContext } from '@/store/chat-persona'
import type { SessionMessage } from '@/types/hermes'

import { stubThreadEnvironment, ThreadRuntime } from '../test-utils'

import { AgentDeliveryNotice, deliveryTargetFromCommand, replyTextFromResult } from './agent-delivery'

import { Thread } from '.'

stubThreadEnvironment()
afterEach(cleanup)

const botPersona: ChatPersona = { avatar: () => null, name: 'Zeta' }

const inChat = (persona: ChatPersona | null, children: ReactNode) => (
  <ChatPersonaContext.Provider value={persona}>{children}</ChatPersonaContext.Provider>
)

// Sender-side inter-agent deliveries render as "Messaged X" / "Message from
// X" notices instead of terminal transcript rows. This pins the detection
// (the canonical Bot Mode command shape) and the reply extraction.
describe('delivery command detection', () => {
  it('matches the canonical delivery command', () => {
    const cmd = 'hermes -p turqoise chat --in ~ -c "Bot Chat" -Q -q "Message from 🤖 Hermes (@hermes): hi there"'

    expect(deliveryTargetFromCommand(cmd)).toBe('turqoise')
  })

  it('matches with a cd prefix and timeout wrapper', () => {
    const cmd = 'cd ~ && timeout 240 hermes -p mr-tester chat --in "~" -Q -q "Message from 🤖 Hermes: hello"'

    expect(deliveryTargetFromCommand(cmd)).toBe('mr-tester')
  })

  it('ignores ordinary terminal commands', () => {
    expect(deliveryTargetFromCommand('ls -la')).toBeNull()
    expect(deliveryTargetFromCommand('hermes -p turqoise chat -q "plain question"')).toBeNull()
    expect(deliveryTargetFromCommand('hermes sessions list')).toBeNull()
  })
})

describe('reply extraction', () => {
  it('strips session_id bookkeeping and keeps the reply', () => {
    const output = 'session_id: 20260813_220347_f69ac6\nHi Hermes! Good to hear from you.'

    expect(replyTextFromResult({ output })).toBe('Hi Hermes! Good to hear from you.')
  })

  it('unwraps JSON-shaped terminal results', () => {
    const result = JSON.stringify({ exit_code: 0, output: 'session_id: abc\nack' })

    expect(replyTextFromResult(result)).toBe('ack')
  })

  it('returns empty for empty results', () => {
    expect(replyTextFromResult(undefined)).toBe('')
    expect(replyTextFromResult({ output: '' })).toBe('')
  })
})

const DELIVERY_COMMAND = 'hermes -p scribe chat -Q -q "Message from 🤖 Hermes (@hermes): hi there"'

const DELIVERY_RESULT_PROPS = {
  args: { command: DELIVERY_COMMAND },
  result: { exit_code: 0, output: 'session_id: abc\nthe scribe replied' },
  toolName: 'terminal'
}

const renderDeliveryNotice = (persona: ChatPersona | null) =>
  render(
    inChat(
      persona,
      <AgentDeliveryNotice {...(DELIVERY_RESULT_PROPS as unknown as ComponentProps<typeof AgentDeliveryNotice>)} />
    )
  )

const renderInboundNote = (persona: ChatPersona | null) => {
  const messages = toChatMessages([
    { role: 'user', content: 'Message from 🤖 Scribe (@scribe): the delivered body', timestamp: 1 } as SessionMessage
  ]).map(toRuntimeMessage)

  const view = render(
    inChat(
      persona,
      <ThreadRuntime messages={messages}>
        <Thread />
      </ThreadRuntime>
    )
  )

  fireEvent.click(view.getByRole('button', { name: /message with Scribe/ }))

  return view
}

describe('delivery notices keep the message body one click away outside Bot Mode', () => {
  it('offers the reply body behind "show message" in a regular chat', () => {
    const { container } = renderDeliveryNotice(null)

    expect(container.querySelector('details')?.textContent).toContain('the scribe replied')
  })

  it('shows only the compact notice inside a bot chat', () => {
    const { container } = renderDeliveryNotice(botPersona)

    expect(container.querySelector('[data-slot="aui_agent-reply-notice"]')).not.toBeNull()
    expect(container.querySelector('details')).toBeNull()
  })

  it('offers the delivered body behind "show message" on an inbound note in a regular chat', () => {
    const { container } = renderInboundNote(null)

    expect(container.querySelector('[data-slot="aui_agent-message-note"] details')?.textContent).toContain(
      'the delivered body'
    )
  })

  it('shows only the compact inbound note inside a bot chat', () => {
    const { container } = renderInboundNote(botPersona)

    expect(container.querySelector('[data-slot="aui_agent-message-note"]')).not.toBeNull()
    expect(container.querySelector('details')).toBeNull()
  })
})
