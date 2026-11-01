import { type ChatPersona, type ChatVoiceLabels, host, setChatPersonas, setHandlePersonas } from '@hermes/plugin-sdk'

import { avatarColor, botAppearance, BotFace } from './avatar'
import { isBackfilledFacePng } from './avatar-image'
import { $selectedBot } from './bot-state'
import { $botMeta, $lastRoster, botHandle, botSelectionKey } from './data'
import { botsText } from './i18n'
import { displayName } from './labels'
import { botRosterMeta } from './routing'
import { ID } from './shared'
import type { RosterRow } from './types'

let personaCache = new Map<string, ChatPersona>()

function voiceLabels(): ChatVoiceLabels {
  const { ended, ...labels } = botsText().voice.call

  return { ...labels, callEnded: ended }
}

function personaFor(bot: RosterRow, live: Map<string, ChatPersona>): ChatPersona {
  const meta = botRosterMeta(bot, $botMeta.get())
  const { color, image, shape } = botAppearance(bot.name, meta)
  const photo = Boolean(image && !isBackfilledFacePng(image))
  const name = displayName(bot, meta)
  const key = JSON.stringify([bot.name, name, color, photo ? image : null, shape])
  const cached = personaCache.get(key)

  if (cached) {
    live.set(key, cached)

    return cached
  }

  const persona: ChatPersona = {
    name,
    openDetails: () => {
      $selectedBot.set(botSelectionKey(bot))
      host.revealPane(`${ID}:routines`)
    },
    stopNowLabel: () => botsText().canonical.stopNow,
    voice: voiceLabels,
    avatar: size => (
      <BotFace
        color={avatarColor(color, bot.name)}
        image={photo ? image : null}
        mood="idle"
        name={bot.name}
        shape={shape}
        size={size}
      />
    )
  }

  live.set(key, persona)

  return persona
}

function handleKey(value: string): string {
  return value.trim().toLowerCase()
}

function claimHandle(byHandle: Record<string, ChatPersona>, key: string, persona: ChatPersona): void {
  if (key && !Object.hasOwn(byHandle, key)) {
    byHandle[key] = persona
  }
}

function personas(roster: readonly RosterRow[]): {
  byHandle: Record<string, ChatPersona>
  bySession: Record<string, ChatPersona>
} {
  const byHandle: Record<string, ChatPersona> = {}
  const bySession: Record<string, ChatPersona> = {}
  const live = new Map<string, ChatPersona>()
  const entries = roster.map(bot => ({ bot, persona: personaFor(bot, live) }))

  for (const { bot, persona } of entries) {
    claimHandle(byHandle, handleKey(bot.name), persona)
  }

  for (const { bot, persona } of entries) {
    claimHandle(byHandle, handleKey(botHandle(bot.name, bot)), persona)

    if (handleKey(bot.name) === 'default') {
      claimHandle(byHandle, 'hermes', persona)
    }
  }

  for (const { bot, persona } of entries) {
    for (const id of [bot.canonical_session?.id, bot.canonical_session?.resolved_id]) {
      if (id) {
        bySession[id] = persona
      }
    }
  }

  personaCache = live

  return { byHandle, bySession }
}

export function startBotChatPersonas(): () => void {
  const apply = () => {
    const roster = $lastRoster.get()

    const { byHandle, bySession } = personas(Array.isArray(roster) ? roster : [])

    setChatPersonas(bySession)
    setHandlePersonas(byHandle)
  }

  const stops = [$lastRoster, $botMeta].map(store => store.listen(apply))

  apply()

  return () => {
    stops.forEach(stop => stop())
    personaCache.clear()
    setChatPersonas({})
    setHandlePersonas({})
  }
}
