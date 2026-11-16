import type { GatewayEvent } from '@hermes/shared'

import { sealAcceptedCorrection, sealLiveStream } from '@/app/session/hooks/use-prompt-actions/rewind'
import type { ClientSessionState } from '@/app/types'
import { type ChatMessage, textPart } from '@/lib/chat-messages'

import type { GatewayEventContext } from './types'

interface AbsorbedInput {
  admissionIds: string[]
  text: string
}

function absorbedInput(event: GatewayEvent): AbsorbedInput | null {
  const body = (event.payload ?? event) as Record<string, unknown>

  const admissionIds = Array.isArray(body.admission_ids)
    ? body.admission_ids.filter((id): id is string => typeof id === 'string' && id.length > 0)
    : []

  return admissionIds.length ? { admissionIds, text: typeof body.text === 'string' ? body.text : '' } : null
}

function absorbOwnerInput(state: ClientSessionState, input: AbsorbedInput, occurredAt: number): ClientSessionState {
  const echoIds = new Set(input.admissionIds.map(id => `user-${id}`))
  const echo = state.messages.find(message => message.role === 'user' && echoIds.has(message.id))

  if (echo) {
    return sealAcceptedCorrection(state, echo.id, { keepRunningTools: true })
  }

  if (!input.text.trim()) {
    return state
  }

  const bubble: ChatMessage = {
    id: `user-${input.admissionIds[0]}`,
    role: 'user',
    parts: [textPart(input.text)],
    timestamp: occurredAt
  }

  const sealed = sealLiveStream(state, { keepRunningTools: true })

  return { ...sealed, messages: [...sealed.messages, bubble] }
}

export function handleInputAbsorbedEvent({ deps, event, occurredAt, sessionId }: GatewayEventContext): boolean {
  if (event.type !== 'input.absorbed') {
    return false
  }

  const input = sessionId ? absorbedInput(event) : null

  if (sessionId && input) {
    deps.flushQueuedDeltas(sessionId)
    deps.updateSessionState(sessionId, state => absorbOwnerInput(state, input, occurredAt))
  }

  return true
}
