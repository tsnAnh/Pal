import type { DisplayLease, ScreenViewer } from './screen-connection'
import { leaseHeldBy } from './screen-connection'

export interface HandbackAsk {
  reason: string
  requestedAt: number
}

export type HandbackPhase = 'checking' | 'elsewhere' | 'inControl' | 'pending' | 'resolved' | 'unavailable'

function asRecord(value: unknown): Record<string, unknown> | null {
  if (typeof value === 'string') {
    try {
      return asRecord(JSON.parse(value))
    } catch {
      return null
    }
  }

  return value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, unknown>) : null
}

/** What the `request_handback` call said: the reason to show and the lease generation of the ask. A result
 *  the backend did not accept (error body, no timestamp) is not a card. */
export function parseHandbackAsk(args: unknown, result: unknown): HandbackAsk | null {
  const body = asRecord(result)
  const requestedAt = body?.requested_at

  if (!body || body.success !== true || typeof requestedAt !== 'number') {
    return null
  }

  const stated = typeof body.reason === 'string' ? body.reason : ''
  const argued = asRecord(args)?.reason
  const reason = (stated || (typeof argued === 'string' ? argued : '')).trim()

  return reason ? { reason, requestedAt } : null
}

/** The card's state is derived from the lease alone (the single truth): the ask is pending while the lease
 *  still carries THIS ask, and settled once it carries none or a newer one. */
export function handbackPhase(
  ask: HandbackAsk,
  lease: DisplayLease | null,
  viewer: ScreenViewer | null,
  unavailable: boolean
): HandbackPhase {
  if (unavailable) {
    return 'unavailable'
  }

  if (!lease) {
    return 'checking'
  }

  if (!lease.ask || lease.ask_at !== ask.requestedAt) {
    return 'resolved'
  }

  if (lease.holder !== 'human') {
    return 'pending'
  }

  return leaseHeldBy(lease, viewer) ? 'inControl' : 'elsewhere'
}
