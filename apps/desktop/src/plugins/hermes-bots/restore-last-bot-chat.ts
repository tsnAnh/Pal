import { host } from '@hermes/plugin-sdk'

import { $openBotChat, saveSelectedRosterBot } from './bot-state'
import { openBotCanonicalChat, prepareBotSource } from './canonical-chat'
import { $botMeta, botActivitySession, botRosterKey, cachedUnionRoster, primeRoster } from './data'
import { botRosterMeta, resolveBotConnectionRoute } from './routing'
import { botCanonicalSessionId } from './row-helpers'
import { getBotOpenGeneration } from './shared'
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

function sourceStatus(sources: readonly GatewaySource[], connectionId: string): 'missing' | 'pending' {
  if (sources.length === 0) {
    return 'missing'
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
  sources: readonly GatewaySource[]
): { bot: RosterRow } | { status: 'missing' | 'pending' } {
  if (target.kind === 'bot') {
    const bot = profiles.find(row => {
      const identity = botChatIdentity(row)

      return identity.connectionId === target.connectionId && identity.profile === target.profile && usable(row)
    })

    return bot ? { bot } : { status: sourceStatus(sources, target.connectionId) }
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

  return bot ? { bot } : { status: sourceStatus(sources, primaryConnectionId) }
}

async function openRestored(bot: RosterRow, isCurrent: () => boolean): Promise<PluginBotChatRestoreResult> {
  const generation = getBotOpenGeneration()
  const stillCurrent = () => isCurrent() && getBotOpenGeneration() === generation

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
      openingStillCurrent: () => getBotOpenGeneration() === generation
    })

    if (getBotOpenGeneration() !== generation) {
      return { status: 'superseded' }
    }

    if (!opened) {
      return { status: 'missing' }
    }

    saveSelectedRosterBot(bot)
    $openBotChat.set({
      key: botRosterKey(bot),
      openedRegistryId: opened.registryId,
      openedSessionId: opened.openedId
    })

    return { ...botChatIdentity(bot), status: 'opened' }
  } catch (error) {
    console.warn('[hermes-bots] restoring the last Bot Chat failed', error instanceof Error ? error.message : 'unknown error')

    return { status: 'failed' }
  }
}

export async function restoreBotChat(
  target: PluginBotChatTarget,
  isCurrent: () => boolean
): Promise<PluginBotChatRestoreResult> {
  await primeRoster()
  const snapshot = cachedUnionRoster()

  if (!Array.isArray(snapshot?.profiles)) {
    return { status: 'pending' }
  }

  const sources = Array.isArray(snapshot.sources) ? snapshot.sources : []
  const primaryConnectionId = String(snapshot.primaryConnectionId || ambientConnectionId()).trim()
  const resolved = resolveTarget(target, snapshot.profiles, primaryConnectionId, sources)

  return 'bot' in resolved ? openRestored(resolved.bot, isCurrent) : { status: resolved.status }
}

export function registerLastBotChatRestorer(): () => void {
  return typeof host.sessions?.registerBotChatRestorer === 'function'
    ? host.sessions.registerBotChatRestorer(restoreBotChat)
    : () => undefined
}
