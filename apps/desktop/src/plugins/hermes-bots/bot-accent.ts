import { normalizeHex, readableOn } from '@hermes/plugin-sdk'

import { avatarColor, botAppearance } from './avatar'
import { $botMeta, $lastRoster } from './data'
import { botRosterMeta } from './routing'
import type { RosterRow } from './types'

const STYLE_ID = 'hermes-bot-chat-accent'

const HSL_RE = /^hsla?\(\s*(-?[\d.]+)(?:deg)?[\s,]+([\d.]+)%[\s,]+([\d.]+)%/i

function hslToHex(color: string): null | string {
  const match = HSL_RE.exec(color.trim())

  if (!match) {
    return null
  }

  const hue = (((Number(match[1]) % 360) + 360) % 360) / 30
  const sat = Math.min(Number(match[2]), 100) / 100
  const light = Math.min(Number(match[3]), 100) / 100
  const spread = sat * Math.min(light, 1 - light)

  const channel = (offset: number) => {
    const k = (offset + hue) % 12
    const value = light - spread * Math.max(-1, Math.min(k - 3, 9 - k, 1))

    return Math.round(value * 255)
      .toString(16)
      .padStart(2, '0')
  }

  return `#${channel(0)}${channel(8)}${channel(4)}`
}

function botAccent(bot: RosterRow): null | string {
  const { color } = botAppearance(bot.name, botRosterMeta(bot, $botMeta.get()))
  const resolved = avatarColor(color, bot.name)

  return normalizeHex(resolved) ?? hslToHex(resolved)
}

function accentRules(roster: readonly RosterRow[]): string {
  return roster
    .flatMap(bot => {
      const accent = botAccent(bot)
      const ids = [bot.canonical_session?.id, bot.canonical_session?.resolved_id]

      if (!accent) {
        return []
      }

      return [...new Set(ids.filter((id): id is string => Boolean(id)))].map(
        id =>
          `[data-chat-surface][data-stored-session-id="${CSS.escape(id)}"]{--dt-bot-accent:${accent};--dt-bot-accent-foreground:${readableOn(accent)}}`
      )
    })
    .join('\n')
}

export function startBotChatAccent(): () => void {
  const style = document.createElement('style')

  style.id = STYLE_ID
  document.head.appendChild(style)

  const apply = () => {
    const roster = $lastRoster.get()

    style.textContent = accentRules(Array.isArray(roster) ? roster : [])
  }

  const stops = [$lastRoster, $botMeta].map(store => store.listen(apply))

  apply()

  return () => {
    stops.forEach(stop => stop())
    style.remove()
  }
}
