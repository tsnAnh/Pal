/**
 * Per-bot teach-a-skill cache: the last `bot.teach.status` the pane saw. The BACKEND owns the recording and the
 * draft; this is a renderer cache of it, replaced wholesale by each reply (never merged: a status is a snapshot).
 */

import type { BotTeachStatus } from '@hermes/plugin-sdk'
import { atom } from 'nanostores'

import { botSelectionKey } from './data'
import { snapshotOf, type TeachSnapshot } from './teach-skill-model'
import type { RosterRow } from './types'

export interface BotTeachState {
  /** The bot's Hermes has no `bot.teach.*` methods (older backend): nothing to show, ever. */
  unavailable: boolean
  snapshot: null | TeachSnapshot
}

export const $teachState = atom<Record<string, BotTeachState>>({})

export function teachStateFor(all: Record<string, BotTeachState>, bot: RosterRow): BotTeachState | null {
  return all[botSelectionKey(bot)] ?? null
}

export function setTeachStatus(bot: RosterRow, status: BotTeachStatus, now = Date.now()): void {
  $teachState.set({
    ...$teachState.get(),
    [botSelectionKey(bot)]: { snapshot: snapshotOf(status, now), unavailable: false }
  })
}

export function setTeachUnavailable(bot: RosterRow): void {
  const key = botSelectionKey(bot)

  if ($teachState.get()[key]?.unavailable) {
    return
  }

  $teachState.set({ ...$teachState.get(), [key]: { snapshot: null, unavailable: true } })
}

/** Bots whose recording started by taking the screen for it: Stop hands the screen back, but only for those, so a
 *  person who was already in control keeps it. */
const tookControlForTeaching = new Set<string>()

export function noteTookControl(bot: RosterRow, took: boolean): void {
  const key = botSelectionKey(bot)

  if (took) {
    tookControlForTeaching.add(key)
  } else {
    tookControlForTeaching.delete(key)
  }
}

export function takeControlNote(bot: RosterRow): boolean {
  const key = botSelectionKey(bot)
  const had = tookControlForTeaching.has(key)

  tookControlForTeaching.delete(key)

  return had
}

/** When the recording was last handed to each bot. "Ask again" waits out the bot's first turn, so a second hidden
 *  turn never races the first one's write. */
const submittedAt = new Map<string, number>()

export const ASK_AGAIN_AFTER_MS = 90_000

export function noteTeachSubmitted(bot: RosterRow, now = Date.now()): void {
  submittedAt.set(botSelectionKey(bot), now)
}

export function askAgainWaitsUntil(bot: RosterRow): number {
  return (submittedAt.get(botSelectionKey(bot)) ?? 0) + ASK_AGAIN_AFTER_MS
}
