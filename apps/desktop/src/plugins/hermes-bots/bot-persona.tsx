import { type ChatPersona, host, setChatPersonas } from '@hermes/plugin-sdk'

import { avatarColor, botAppearance, BotFace } from './avatar'
import { isBackfilledFacePng } from './avatar-image'
import { $botMeta, $lastRoster } from './data'
import { displayName } from './labels'
import { botRosterMeta } from './routing'
import { ID } from './shared'
import type { RosterRow } from './types'

let personaCache = new Map<string, ChatPersona>()

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
    openProfile: typeof host.revealPane === 'function' ? () => host.revealPane(`${ID}:routines`) : undefined,
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

function personas(roster: readonly RosterRow[]): Record<string, ChatPersona> {
  const out: Record<string, ChatPersona> = {}
  const live = new Map<string, ChatPersona>()

  for (const bot of roster) {
    const ids = [bot.canonical_session?.id, bot.canonical_session?.resolved_id].filter((id): id is string =>
      Boolean(id)
    )

    if (!ids.length) {
      continue
    }

    const persona = personaFor(bot, live)

    for (const id of ids) {
      out[id] = persona
    }
  }

  personaCache = live

  return out
}

export function startBotChatPersonas(): () => void {
  const apply = () => {
    const roster = $lastRoster.get()

    setChatPersonas(personas(Array.isArray(roster) ? roster : []))
  }

  const stops = [$lastRoster, $botMeta].map(store => store.listen(apply))

  apply()

  return () => {
    stops.forEach(stop => stop())
    personaCache.clear()
    setChatPersonas({})
  }
}
