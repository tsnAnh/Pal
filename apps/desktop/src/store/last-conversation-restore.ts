import { atom } from 'nanostores'

import { $workspaceMode } from '@/components/pane-shell/workspace-scope'
import { SOURCE_SWITCH_DIAL_TIMEOUT_MS } from '@/lib/with-timeout'

import { $connectionsRegistry } from './connection-registry-state'
import {
  $lastConversation,
  clearLastConversation,
  type LastConversation,
  type LastConversationTarget,
  rememberLastConversation
} from './last-conversation'

export type BotChatTarget = { connectionId: string; kind: 'bot'; profile: string } | { kind: 'primary-most-recent' }

export type BotChatRestoreResult =
  | { connectionId: string; profile: string; status: 'opened' }
  | { status: 'failed' | 'missing' | 'pending' | 'superseded' }

export type BotChatRestorer = (target: BotChatTarget, isCurrent: () => boolean) => Promise<BotChatRestoreResult>

export type RestoreOutcome = 'fallback-opened' | 'home' | 'opened' | 'superseded' | 'timed-out'

export const $botChatRestorer = atom<BotChatRestorer | null>(null)

export function registerBotChatRestorer(restorer: BotChatRestorer): () => void {
  $botChatRestorer.set(restorer)

  return () => {
    if ($botChatRestorer.get() === restorer) {
      $botChatRestorer.set(null)
    }
  }
}

export const RESTORE_POLL_MS = 1_500

export interface RestorePorts {
  clear: () => void
  connectionIds: () => null | ReadonlySet<string>
  isCurrent: () => boolean
  now: () => number
  pointer: () => LastConversation | null
  pollMs: number
  remember: (target: LastConversationTarget) => void
  restorer: () => BotChatRestorer | null
  sleep: (ms: number) => Promise<void>
  timeoutMs: number
}

export function registryConnectionIds(): null | ReadonlySet<string> {
  const registry = $connectionsRegistry.get()

  return registry ? new Set(registry.connections.map(connection => connection.id)) : null
}

export function claimsBootRestore(pointer: LastConversation | null, connectionIds: null | ReadonlySet<string>): boolean {
  if (!pointer) {
    return false
  }

  return pointer.kind === 'bot-chat' || (connectionIds !== null && !connectionIds.has(pointer.connectionId))
}

export function browserRestorePorts(isCurrent: () => boolean): RestorePorts {
  return {
    clear: clearLastConversation,
    connectionIds: registryConnectionIds,
    isCurrent,
    now: Date.now,
    pointer: () => $lastConversation.get(),
    pollMs: RESTORE_POLL_MS,
    remember: rememberLastConversation,
    restorer: () => $botChatRestorer.get(),
    sleep: ms => new Promise(resolve => setTimeout(resolve, ms)),
    timeoutMs: SOURCE_SWITCH_DIAL_TIMEOUT_MS
  }
}

type Step<T> = { value: T } | 'superseded' | 'timed-out'

async function waitFor<T>(ports: RestorePorts, deadline: number, read: () => null | T): Promise<Step<T>> {
  for (;;) {
    if (!ports.isCurrent()) {
      return 'superseded'
    }

    const value = read()

    if (value !== null) {
      return { value }
    }

    if (ports.now() >= deadline) {
      return 'timed-out'
    }

    await ports.sleep(ports.pollMs)
  }
}

async function attempt(restorer: BotChatRestorer, target: BotChatTarget, ports: RestorePorts) {
  try {
    return await restorer(target, ports.isCurrent)
  } catch (error) {
    console.warn('[last-conversation] restore attempt failed', error instanceof Error ? error.message : 'unknown error')

    return { status: 'failed' } as const
  }
}

async function pursue(
  restorer: BotChatRestorer,
  target: BotChatTarget,
  ports: RestorePorts,
  deadline: number,
  onMissing: () => Promise<RestoreOutcome>,
  openedOutcome: RestoreOutcome
): Promise<RestoreOutcome> {
  for (;;) {
    if (!ports.isCurrent()) {
      return 'superseded'
    }

    const result = await attempt(restorer, target, ports)

    if (result.status === 'opened') {
      ports.remember({ connectionId: result.connectionId, kind: 'bot-chat', profile: result.profile })

      return openedOutcome
    }

    if (result.status === 'superseded') {
      return 'superseded'
    }

    if (result.status === 'missing') {
      return onMissing()
    }

    if (result.status === 'failed') {
      return 'home'
    }

    if (ports.now() >= deadline) {
      return 'timed-out'
    }

    await ports.sleep(ports.pollMs)
  }
}

export async function restoreLastConversation(ports: RestorePorts): Promise<RestoreOutcome> {
  const pointer = ports.pointer()

  if (!pointer) {
    return 'home'
  }

  const deadline = ports.now() + ports.timeoutMs
  const registry = await waitFor(ports, deadline, ports.connectionIds)

  if (typeof registry === 'string') {
    return registry
  }

  const readyRestorer = await waitFor(ports, deadline, ports.restorer)

  if (typeof readyRestorer === 'string') {
    return readyRestorer
  }

  const restorer = readyRestorer.value

  const fallback = async (): Promise<RestoreOutcome> => {
    const outcome = await pursue(restorer, { kind: 'primary-most-recent' }, ports, deadline, async () => 'home', 'fallback-opened')

    if (outcome === 'home' || outcome === 'timed-out') {
      ports.clear()

      return 'home'
    }

    return outcome
  }

  if (!registry.value.has(pointer.connectionId)) {
    return fallback()
  }

  if (pointer.kind === 'session') {
    return 'home'
  }

  return pursue(
    restorer,
    { connectionId: pointer.connectionId, kind: 'bot', profile: pointer.profile },
    ports,
    deadline,
    fallback,
    'opened'
  )
}

export function recordSessionConversation({
  connectionId,
  profile,
  sessionId
}: {
  connectionId: null | string
  profile: string
  sessionId: string
}): void {
  if (!connectionId || $workspaceMode.get() === 'bots') {
    return
  }

  rememberLastConversation({ connectionId, kind: 'session', profile, sessionId })
}
