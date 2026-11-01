import { botJob } from './bot-detail-model'
import { stripPreviewMarkdown } from './labels'
import { A2A_PREFIX_RE, previewKind } from './row-helpers'
import type { BotMeta, RosterRow } from './types'

interface RosterPreview {
  fromBot: null | string
  text: string
}

function chatPreview(bot: RosterRow): string | undefined {
  const candidates = [bot.canonical_session?.preview, bot.last_session?.preview]

  return candidates.find(preview => stripPreviewMarkdown(preview)) ?? undefined
}

export function rosterPreview(
  bot: RosterRow,
  meta: BotMeta | null | undefined,
  roster: readonly Partial<RosterRow>[] = []
): RosterPreview {
  const preview = chatPreview(bot)

  if (preview) {
    const { fromBot } = previewKind(preview, roster, bot.connectionId)

    const text = fromBot
      ? stripPreviewMarkdown(preview.replace(A2A_PREFIX_RE, '')) || '…'
      : stripPreviewMarkdown(preview)

    return { fromBot, text }
  }

  const job = botJob(bot.description ?? meta?.description, meta?.title ?? bot.title)

  return { fromBot: null, text: stripPreviewMarkdown(job) }
}
