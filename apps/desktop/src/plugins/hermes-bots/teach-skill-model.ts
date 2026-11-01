import type { BotTeachPending, BotTeachStatus } from '@hermes/plugin-sdk'

export type TeachPhase = 'drafting' | 'ended' | 'hidden' | 'idle' | 'ready' | 'recording'

export interface TeachSnapshot {
  receivedAt: number
  skewMs: number
  status: BotTeachStatus
}

const MS = 1000
const POLL_RECORDING_MS = 2000
const POLL_DRAFTING_MS = 3000
const POLL_ENDED_MS = 5000

export function snapshotOf(status: BotTeachStatus, receivedAt: number): TeachSnapshot {
  return { receivedAt, skewMs: status.now * MS - receivedAt, status }
}

/** What the controls show. `hidden` covers a gateway without the methods, a screen that cannot be taught (no
 *  Chromium reachable, terminal sandbox) and a pane that is not live yet. An unresolved draft outranks everything:
 *  there is only ever one per bot, and it must be settled before another lesson starts. */
export function teachPhase(snapshot: null | TeachSnapshot, live: boolean): TeachPhase {
  const status = snapshot?.status

  if (!status || !live) {
    return 'hidden'
  }

  if (status.recording) {
    return 'recording'
  }

  if (status.ended) {
    return 'ended'
  }

  if (status.pending) {
    return status.pending.state === 'ready' ? 'ready' : 'drafting'
  }

  return status.available ? 'idle' : 'hidden'
}

/** Seconds left in the recording, on the gateway's clock (corrected by the skew measured when the status arrived). */
export function secondsLeft(snapshot: TeachSnapshot, nowMs: number): number {
  const { deadline_at: deadline } = snapshot.status

  return deadline == null ? 0 : Math.max(0, Math.ceil(deadline - (nowMs + snapshot.skewMs) / MS))
}

export function formatClock(seconds: number): string {
  const whole = Math.max(0, Math.floor(seconds))

  return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, '0')}`
}

/** How long until the status should be asked again; `null` = nothing is moving, no polling. */
export function pollDelay(status: BotTeachStatus | null): null | number {
  if (!status) {
    return null
  }

  if (status.recording) {
    return POLL_RECORDING_MS
  }

  if (status.ended) {
    return POLL_ENDED_MS
  }

  return status.pending?.state === 'drafting' ? POLL_DRAFTING_MS : null
}

export function pendingOf(snapshot: null | TeachSnapshot): BotTeachPending | null {
  return snapshot?.status.pending ?? null
}

/** The gateway's refusal code (`data.code`) of a failed teach call, else `''`. */
export function teachErrorCode(error: unknown): string {
  const data = (error as { data?: { code?: unknown } } | null)?.data

  return typeof data?.code === 'string' ? data.code : ''
}
