import type { ThreadPrimitive } from '@assistant-ui/react'
import { useAuiState } from '@assistant-ui/react'
import { type ComponentProps, type FC, useState } from 'react'

import { useI18n } from '@/i18n'

import { AgentGlyph, dispatchedTo } from './agent-delivery'
import { messageContentText } from './content'
import { AGENT_MESSAGE_RE } from './content'
import { ResponseMessages } from './response-group'

type PeerSourceMessage = { content?: unknown; role?: string }

type FlagSourceMessage = {
  content?: unknown
  metadata?: { custom?: Record<string, unknown> }
  status?: { type?: string }
}

const ATTENTION_TOOLS = new Set(['clarify'])

function needsAttention(message: FlagSourceMessage): boolean {
  const status = message.status?.type

  if (status === 'incomplete' || status === 'requires-action') {
    return true
  }

  return (
    Array.isArray(message.content) &&
    message.content.some(
      (part: { result?: unknown; toolName?: unknown; type?: unknown }) =>
        part?.type === 'tool-call' && ATTENTION_TOOLS.has(String(part.toolName)) && part.result === undefined
    )
  )
}

export function structuralFlags(message: FlagSourceMessage): string {
  return `${message.metadata?.custom?.afterHiddenNotice ? 'b' : ''}${needsAttention(message) ? 'a' : ''}`
}

const peerKeyCache = new WeakMap<object, string>()

function peerKey(match: RegExpExecArray): string {
  return (match[2] || match[3] || match[1] || '').trim().toLowerCase().replace(/[:\n]/g, '')
}

export function peerOfMessage(messages: readonly PeerSourceMessage[], index: number): string {
  const message = messages[index]

  if (message?.role !== 'user') {
    return ''
  }

  const cached = peerKeyCache.get(message)

  if (cached !== undefined) {
    return cached
  }

  const match = AGENT_MESSAGE_RE.exec(messageContentText(message.content as never).trim())

  const peer = match && !dispatchedTo(messages.slice(0, index), [match[1], match[2], match[3]]) ? peerKey(match) : ''

  peerKeyCache.set(message, peer)

  return peer
}

function usePeerIdentity(index: number): { handle: string; name: string } {
  const text = useAuiState(s => messageContentText((s.thread.messages[index]?.content ?? []) as never).trim())
  const match = AGENT_MESSAGE_RE.exec(text)
  const name = (match?.[1] || match?.[3] || 'agent').trim()

  return { handle: (match?.[2] || match?.[3] || name).trim(), name }
}

interface PeerRunProps {
  attention: boolean
  components: ComponentProps<typeof ThreadPrimitive.MessageByIndex>['components']
  count: number
  live: boolean
  turns: readonly (readonly number[])[]
}

export const PeerRun: FC<PeerRunProps> = ({ attention, components, count, live, turns }) => {
  const { t } = useI18n()
  const forceOpen = live || attention
  const [open, setOpen] = useState(forceOpen)
  const [forcedOpen, setForcedOpen] = useState(forceOpen)
  const { handle, name } = usePeerIdentity(turns[0]![0]!)

  if (forceOpen && !forcedOpen) {
    setForcedOpen(true)
    setOpen(true)
  }

  const expanded = open

  return (
    <div className="flex min-w-0 flex-col gap-(--conversation-turn-gap)" data-slot="aui_peer-run">
      <button
        aria-expanded={expanded}
        className="flex max-w-[min(86%,44rem)] items-center justify-center gap-1.5 self-center px-2 py-0.5 text-[0.6875rem] leading-5 text-muted-foreground/60 hover:text-muted-foreground/85"
        onClick={() => setOpen(!open)}
        type="button"
      >
        <AgentGlyph handle={handle} />
        <span className="wrap-anywhere">{t.assistant.thread.peerRun(count, name)}</span>
      </button>
      {expanded &&
        turns.map(indices => (
          <div
            className="composer-human-ai-pair-container relative flex min-w-0 flex-col gap-(--conversation-turn-gap)"
            data-slot="aui_turn-pair"
            key={indices[0]}
          >
            <ResponseMessages components={components} indices={indices} />
          </div>
        ))}
    </div>
  )
}
