import { atom } from 'nanostores'

import { readJson, writeJson } from '@/lib/storage'

const LAST_CONVERSATION_KEY = 'hermes.desktop.lastConversation.v1'

export interface ConversationScope {
  connectionId: string
  profile: string
}

export interface BotChatConversation extends ConversationScope {
  kind: 'bot-chat'
  updatedAt: number
}

export interface SessionConversation extends ConversationScope {
  kind: 'session'
  sessionId: string
  updatedAt: number
}

export type LastConversation = BotChatConversation | SessionConversation

export type LastConversationTarget = Omit<BotChatConversation, 'updatedAt'> | Omit<SessionConversation, 'updatedAt'>

function text(value: unknown): string {
  return typeof value === 'string' ? value.trim() : ''
}

function parseLastConversation(raw: unknown): LastConversation | null {
  if (!raw || typeof raw !== 'object') {
    return null
  }

  const record = raw as Record<string, unknown>
  const connectionId = text(record.connectionId)
  const profile = text(record.profile)
  const updatedAt = typeof record.updatedAt === 'number' && Number.isFinite(record.updatedAt) ? record.updatedAt : 0

  if (!connectionId || !profile) {
    return null
  }

  if (record.kind === 'bot-chat') {
    return { connectionId, kind: 'bot-chat', profile, updatedAt }
  }

  const sessionId = text(record.sessionId)

  return record.kind === 'session' && sessionId
    ? { connectionId, kind: 'session', profile, sessionId, updatedAt }
    : null
}

function sameConversation(a: LastConversation | LastConversationTarget, b: LastConversation | LastConversationTarget) {
  return (
    a.kind === b.kind &&
    a.connectionId === b.connectionId &&
    a.profile === b.profile &&
    (a.kind !== 'session' || (b.kind === 'session' && a.sessionId === b.sessionId))
  )
}

export const $lastConversation = atom<LastConversation | null>(parseLastConversation(readJson(LAST_CONVERSATION_KEY)))

$lastConversation.listen(value => writeJson(LAST_CONVERSATION_KEY, value))

if (typeof window !== 'undefined') {
  window.addEventListener('storage', event => {
    if (event.key === LAST_CONVERSATION_KEY) {
      const synced = parseLastConversation(readJson(LAST_CONVERSATION_KEY))

      if (JSON.stringify(synced) !== JSON.stringify($lastConversation.get())) {
        $lastConversation.set(synced)
      }
    }
  })
}

export function rememberLastConversation(target: LastConversationTarget, now: number = Date.now()): void {
  const connectionId = text(target.connectionId)
  const profile = text(target.profile)
  const current = $lastConversation.get()

  if (!connectionId || !profile) {
    return
  }

  const next: LastConversation =
    target.kind === 'session'
      ? { connectionId, kind: 'session', profile, sessionId: text(target.sessionId), updatedAt: now }
      : { connectionId, kind: 'bot-chat', profile, updatedAt: now }

  if (next.kind === 'session' && !next.sessionId) {
    return
  }

  if (current && sameConversation(current, next)) {
    return
  }

  $lastConversation.set(next)
}

export function clearLastConversation(): void {
  $lastConversation.set(null)
}
