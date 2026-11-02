import { host } from '@hermes/plugin-sdk'

import { $openBotChat, saveSelectedRosterBot } from './bot-state'
import { openBotCanonicalChat, prepareBotSource } from './canonical-chat'
import { $botMeta, $lastRoster, botActivitySession, botRosterKey, cachedUnionRoster, primeRoster } from './data'
import { botRosterMeta, resolveBotConnectionRoute } from './routing'
import { botCanonicalSessionId } from './row-helpers'
import { $pendingBotOpen, getBotOpenGeneration } from './shared'
import type { GatewaySource, RosterRow } from './types'

type BotChatRestorer = Parameters<typeof host.sessions.registerBotChatRestorer>[0]
type PluginBotChatTarget = Parameters<BotChatRestorer>[0]
type PluginBotChatRestoreResult = Awaited<ReturnType<BotChatRestorer>>

export interface BotChatIdentity {
  connectionId: string
  profile: string
}

function ambientConnectionId(): string {
  return String(host.state.connectionId?.get?.() || host.activeConnectionId?.() || 'local').trim() || 'local'
}

export function botChatIdentity(bot: RosterRow): BotChatIdentity {
  const route = resolveBotConnectionRoute(bot).route

  return {
    connectionId: String(route?.connectionId || bot.connectionId || '').trim() || ambientConnectionId(),
    profile: String(route?.profile || bot.name || '').trim() || 'default'
  }
}

export function rememberBotChat(bot: RosterRow): void {
  if (typeof host.sessions?.rememberBotChat === 'function') {
    host.sessions.rememberBotChat(botChatIdentity(bot))
  }
}

function usable(bot: RosterRow): boolean {
  return !bot.ghost && !bot.retained && !bot.sourceMissing && !bot.unserved && bot.sourceReachable !== false
}

function sourceStatus(
  sources: readonly GatewaySource[] | undefined,
  connectionId: string,
  rosterEmpty: boolean
): 'missing' | 'pending' {
  if (rosterEmpty || !sources?.length) {
    return 'pending'
  }

  return sources.find(source => source.connectionId === connectionId)?.reachable ? 'missing' : 'pending'
}

function mostRecentlyActive(bots: readonly RosterRow[]): null | RosterRow {
  let best: null | RosterRow = null
  let bestAt = -1

  for (const bot of bots) {
    const at = botActivitySession(bot)?.last_active || 0

    if (at > bestAt) {
      best = bot
      bestAt = at
    }
  }

  return best
}

function resolveTarget(
  target: PluginBotChatTarget,
  profiles: readonly RosterRow[],
  primaryConnectionId: string,
  sources: readonly GatewaySource[] | undefined
): { bot: RosterRow } | { status: 'missing' | 'pending' } {
  if (target.kind === 'bot') {
    const bot = profiles.find(row => {
      const identity = botChatIdentity(row)

      return identity.connectionId === target.connectionId && identity.profile === target.profile && usable(row)
    })

    return bot ? { bot } : { status: sourceStatus(sources, target.connectionId, profiles.length === 0) }
  }

  const bot = mostRecentlyActive(
    profiles.filter(
      row =>
        usable(row) &&
        botChatIdentity(row).connectionId === primaryConnectionId &&
        botCanonicalSessionId(row) &&
        !botRosterMeta(row, $botMeta.get())?.hidden
    )
  )

  return bot ? { bot } : { status: sourceStatus(sources, primaryConnectionId, profiles.length === 0) }
}

interface OpenBaseline {
  claim: ReturnType<typeof $openBotChat.get>
  generation: number
}

const restoreBaselines = new WeakMap<() => boolean, OpenBaseline>()
let registrationBaseline: null | OpenBaseline = null

function openBaseline(): OpenBaseline {
  return { claim: $openBotChat.get(), generation: getBotOpenGeneration() }
}

function baselineFor(isCurrent: () => boolean): OpenBaseline {
  let baseline = restoreBaselines.get(isCurrent)

  if (!baseline) {
    baseline = registrationBaseline ?? openBaseline()
    restoreBaselines.set(isCurrent, baseline)
  }

  return baseline
}

function untouchedSince(baseline: OpenBaseline): boolean {
  return getBotOpenGeneration() === baseline.generation && $openBotChat.get() === baseline.claim
}

async function openRestored(bot: RosterRow, isCurrent: () => boolean): Promise<PluginBotChatRestoreResult> {
  const baseline = baselineFor(isCurrent)
  const stillCurrent = () => isCurrent() && untouchedSince(baseline)

  if (!stillCurrent()) {
    return { status: 'superseded' }
  }

  try {
    await prepareBotSource(bot)

    if (!stillCurrent()) {
      return { status: 'superseded' }
    }

    const opened = await openBotCanonicalChat(bot, {
      createIfMissing: false,
      intent: 'in-place',
      openingStillCurrent: stillCurrent
    })

    if (!untouchedSince(baseline)) {
      return { status: 'superseded' }
    }

    if (!opened) {
      return isCurrent() ? { status: 'missing' } : { status: 'superseded' }
    }

    saveSelectedRosterBot(bot)
    $openBotChat.set({
      key: botRosterKey(bot),
      openedRegistryId: opened.registryId,
      openedSessionId: opened.openedId
    })

    return { ...botChatIdentity(bot), status: 'opened' }
  } catch (error) {
    console.warn(
      '[hermes-bots] restoring the last Bot Chat failed',
      error instanceof Error ? error.message : 'unknown error'
    )

    return { status: 'pending' }
  }
}

export async function restoreBotChat(
  target: PluginBotChatTarget,
  isCurrent: () => boolean
): Promise<PluginBotChatRestoreResult> {
  const baseline = baselineFor(isCurrent)

  await primeRoster()

  if (!isCurrent() || !untouchedSince(baseline)) {
    return { status: 'superseded' }
  }

  const snapshot = cachedUnionRoster()

  if (!Array.isArray(snapshot?.profiles)) {
    return { status: 'pending' }
  }

  const sources = Array.isArray(snapshot.sources) ? snapshot.sources : undefined
  const primaryConnectionId = String(snapshot.primaryConnectionId || ambientConnectionId()).trim()
  const resolved = resolveTarget(target, snapshot.profiles, primaryConnectionId, sources)

  return 'bot' in resolved ? openRestored(resolved.bot, isCurrent) : { status: resolved.status }
}

function rosterRows(): readonly RosterRow[] {
  const painted = $lastRoster.get()

  return painted.length ? painted : (cachedUnionRoster()?.profiles ?? [])
}

function canonicalIds(bot: RosterRow): string[] {
  return [bot.canonical_session?.id, bot.canonical_session?.resolved_id].filter(Boolean).map(String)
}

function classifyFocusedConversation(storedSessionId: string): BotChatIdentity | 'session' | 'unknown' {
  const rows = rosterRows()
  const claim = $openBotChat.get()

  if (claim && [claim.openedSessionId, claim.openedRegistryId].includes(storedSessionId)) {
    const claimed = rows.find(row => botRosterKey(row) === claim.key)

    return claimed ? botChatIdentity(claimed) : 'unknown'
  }

  const bot = rows.find(row => canonicalIds(row).includes(storedSessionId))

  if (bot) {
    return botChatIdentity(bot)
  }

  return $pendingBotOpen.get() ? 'unknown' : 'session'
}

function rememberClaimedBot(claim: ReturnType<typeof $openBotChat.get>): void {
  const bot = claim && rosterRows().find(row => botRosterKey(row) === claim.key)

  if (bot) {
    rememberBotChat(bot)
  }
}

export function registerBotChatReopen(): () => void {
  if (typeof host.sessions?.registerBotChatRestorer !== 'function') {
    return () => undefined
  }

  registrationBaseline = openBaseline()

  const stops = [
    host.sessions.registerBotChatRestorer(restoreBotChat),
    host.sessions.registerFocusedConversationClassifier(classifyFocusedConversation),
    $openBotChat.listen(rememberClaimedBot)
  ]

  return () => {
    registrationBaseline = null

    for (const stop of stops) {
      stop()
    }
  }
}
