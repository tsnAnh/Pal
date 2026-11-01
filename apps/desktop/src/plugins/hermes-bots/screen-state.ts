/**
 * Per-bot Bot Screen cache: backend truth (`display.status`) plus the last
 * `display.lease` event, keyed by the bot's roster identity. Renderer-owned
 * cache of backend state — never the authority.
 */

import { atom } from 'nanostores'

import { botSelectionKey } from './data'
import type { DisplayLease, DisplayStatus, ScreenViewer } from './screen-connection'
import type { RosterRow } from './types'

export interface BotScreenState {
  status: DisplayStatus | null
  lease: DisplayLease | null
  /** This window's server-minted identity for the bot's current attach; null until the pane observes. */
  viewer: ScreenViewer | null
  /** The bot's Hermes has no `display.*` methods (older backend): nothing to check, ever. */
  unavailable?: boolean
}

export const $screenState = atom<Record<string, BotScreenState>>({})

export function screenStateFor(all: Record<string, BotScreenState>, bot: RosterRow): BotScreenState | null {
  return all[botSelectionKey(bot)] ?? null
}

/** A lease whose epoch is below the one we hold is a slower response about the
 *  past (a `display.status` reply overtaken by a `display.lease` event). */
function isOlderLease(prev: DisplayLease | null | undefined, next: DisplayLease): boolean {
  return prev != null && next.epoch < prev.epoch
}

/**
 * Per-bot generation of the latest `display.status`-shaped write. A request
 * takes a token from `beginScreenStatusRequest` and hands it back with its
 * reply; a reply whose token was superseded (a newer request, a pushed event,
 * a start/observe result) is a slower answer about the past and is dropped.
 */
const statusGeneration = new Map<string, number>()

export function beginScreenStatusRequest(bot: RosterRow): number {
  const key = botSelectionKey(bot)
  const next = (statusGeneration.get(key) ?? 0) + 1
  statusGeneration.set(key, next)

  return next
}

/** Apply a status snapshot. Without `request` the write is authoritative (an event or a fresh
 *  mutation result) and invalidates every status request still in flight. */
export function setScreenStatus(bot: RosterRow, status: DisplayStatus, request?: number): void {
  const key = botSelectionKey(bot)

  if (request === undefined) {
    statusGeneration.set(key, (statusGeneration.get(key) ?? 0) + 1)
  } else if (request !== statusGeneration.get(key)) {
    return
  }

  const current = $screenState.get()
  const prev = current[key]
  const lease = status.lease && !isOlderLease(prev?.lease, status.lease) ? status.lease : (prev?.lease ?? null)
  $screenState.set({ ...current, [key]: { status, lease, viewer: prev?.viewer ?? null } })
}

/** `display.status` answered method-not-found: remember it so no surface keeps "checking". */
export function setScreenUnavailable(bot: RosterRow): void {
  const key = botSelectionKey(bot)
  const current = $screenState.get()
  const prev = current[key]

  if (prev?.unavailable) {
    return
  }

  $screenState.set({ ...current, [key]: { status: null, lease: null, viewer: null, unavailable: true } })
}

export function setScreenLease(bot: RosterRow, lease: DisplayLease): void {
  const key = botSelectionKey(bot)
  const current = $screenState.get()
  const prev = current[key]

  if (isOlderLease(prev?.lease, lease)) {
    return
  }

  if (
    prev?.lease &&
    prev.lease.holder === lease.holder &&
    prev.lease.viewer_hash === lease.viewer_hash &&
    prev.lease.epoch === lease.epoch
  ) {
    return
  }

  // Same presentation, newer epoch still has to be recorded: otherwise a delayed older event (human@1
  // after agent@0 → agent@2) compares against the stale epoch and rolls the pane back.
  $screenState.set({ ...current, [key]: { status: prev?.status ?? null, lease, viewer: prev?.viewer ?? null } })
}

/** Record the identity `display.observe` minted for this window's attach to `bot`. */
export function setScreenViewer(bot: RosterRow, viewer: ScreenViewer | null): void {
  const key = botSelectionKey(bot)
  const current = $screenState.get()
  const prev = current[key]

  if ((prev?.viewer ?? null) === viewer) {
    return
  }

  $screenState.set({ ...current, [key]: { status: prev?.status ?? null, lease: prev?.lease ?? null, viewer } })
}

/** The bot asked a person to take its screen ("Open computer" on a hand-back card). The pane acquires the
 *  lease once it has a viewer identity; an intent nobody consumed in time is dropped, so a pane that mounts
 *  much later never takes control on a stale click. */
export interface ScreenTakeoverIntent {
  reason: string
  at: number
}

export const TAKEOVER_INTENT_TTL_MS = 20_000

export const $takeoverIntents = atom<Record<string, ScreenTakeoverIntent>>({})

export function pruneExpiredTakeoverIntents(now = Date.now()): void {
  const current = $takeoverIntents.get()
  const live = Object.entries(current).filter(([, intent]) => now - intent.at <= TAKEOVER_INTENT_TTL_MS)

  if (live.length !== Object.keys(current).length) {
    $takeoverIntents.set(Object.fromEntries(live))
  }
}

export function requestScreenTakeover(bot: RosterRow, reason: string, now = Date.now()): void {
  pruneExpiredTakeoverIntents(now)
  $takeoverIntents.set({ ...$takeoverIntents.get(), [botSelectionKey(bot)]: { at: now, reason } })
}

export function clearScreenTakeover(bot: RosterRow): void {
  const key = botSelectionKey(bot)
  const { [key]: dropped, ...rest } = $takeoverIntents.get()

  if (dropped) {
    $takeoverIntents.set(rest)
  }
}

export function liveTakeoverIntent(
  all: Record<string, ScreenTakeoverIntent>,
  bot: RosterRow,
  now = Date.now()
): ScreenTakeoverIntent | null {
  const intent = all[botSelectionKey(bot)]

  return intent && now - intent.at <= TAKEOVER_INTENT_TTL_MS ? intent : null
}
