import { atom, host, queryClient } from '@hermes/plugin-sdk'

import { ROSTER_KEY } from './data'
import { requestForBot } from './routing'
import type { RosterRow } from './types'

export const ONBOARDING_PURPOSES = ['assistant', 'research', 'metrics', 'writing'] as const

export type OnboardingFailure = 'failed' | 'rejected'

const PURPOSE_REJECTED = 4077
const IDENTITY_UNDO_REFUSED = 4078

export const $settledOnboarding = atom<ReadonlySet<string>>(new Set())

export const onboardingPending = (bot: RosterRow, settled: ReadonlySet<string>): boolean =>
  bot.onboarding_pending === true && !settled.has(bot.name)

const rpcCode = (error: unknown): unknown => {
  const carrier = error as { cause?: { code?: unknown }; code?: unknown } | null

  return carrier?.code ?? carrier?.cause?.code
}

export function freshOnboarding(name: string) {
  $settledOnboarding.set(new Set([...$settledOnboarding.get()].filter(settled => settled !== name)))
}

export function settleOnboarding(bot: RosterRow) {
  $settledOnboarding.set(new Set([...$settledOnboarding.get(), bot.name]))
  void queryClient.invalidateQueries({ queryKey: ROSTER_KEY })
}

export async function answerOnboarding(bot: RosterRow, purpose: string): Promise<OnboardingFailure | null> {
  try {
    await requestForBot(bot, 'profiles.onboard', { name: bot.name, purpose })
  } catch (error) {
    return rpcCode(error) === PURPOSE_REJECTED ? 'rejected' : 'failed'
  }

  return null
}

export async function dismissOnboarding(bot: RosterRow): Promise<OnboardingFailure | null> {
  try {
    await requestForBot(bot, 'profiles.onboard', { name: bot.name, dismiss: true })
  } catch {
    return 'failed'
  }

  settleOnboarding(bot)

  return null
}

export type UndoOutcome = 'done' | 'failed' | 'stale'

export async function undoIdentityChange(bot: RosterRow, changeId: string): Promise<UndoOutcome> {
  try {
    await requestForBot(bot, 'profiles.identity.undo', { name: bot.name, change_id: changeId })
  } catch (error) {
    return rpcCode(error) === IDENTITY_UNDO_REFUSED ? 'stale' : 'failed'
  }

  void queryClient.invalidateQueries({ queryKey: ROSTER_KEY })

  return 'done'
}

export function sendFirstMessage(sessionId: null | string, text: string): boolean {
  return typeof host.composer?.submit === 'function' && Boolean(sessionId) && host.composer.submit(sessionId, text)
}
