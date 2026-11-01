import { botJob } from './bot-detail-model'
import { CANONICAL_CHAT_TITLE } from './canonical-chat'
import { displayName } from './labels'
import { botRosterMeta } from './routing'
import type { BotMeta, GroupChat, RosterRow, RoutineJob } from './types'

export const SEARCH_GROUP_LIMIT = 5
export const MESSAGE_MIN_CHARS = 2
export const MESSAGE_FETCH_LIMIT = 50
export const SEARCH_CONCURRENCY = 4
const SNIPPET_RADIUS = 48

export type SearchHit =
  | { bot: RosterRow; key: string; kind: 'bot'; subtitle: string; title: string }
  | { key: string; kind: 'room'; room: string; subtitle: string; title: string }
  | { bot: RosterRow; job: RoutineJob; key: string; kind: 'routine'; subtitle: string; title: string }
  | { bot: RosterRow; key: string; kind: 'chat-message'; subtitle: string; title: string }
  | { key: string; kind: 'room-message'; room: string; subtitle: string; title: string }

export interface SearchGroups {
  bots: SearchHit[]
  messages: SearchHit[]
  rooms: SearchHit[]
  routines: SearchHit[]
}

export interface RoutineSource {
  bot: RosterRow
  jobs: readonly RoutineJob[]
}

export interface SearchSnippetResult {
  session_id: string
  snippet?: null | string
  title?: null | string
}

export async function settleLimited<T, R>(
  items: readonly T[],
  limit: number,
  task: (item: T) => Promise<R>
): Promise<PromiseSettledResult<R>[]> {
  const settled: PromiseSettledResult<R>[] = new Array(items.length)
  let next = 0

  const worker = async () => {
    while (next < items.length) {
      const index = next++

      try {
        settled[index] = { status: 'fulfilled', value: await task(items[index]!) }
      } catch (reason) {
        settled[index] = { reason, status: 'rejected' }
      }
    }
  }

  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker))

  return settled
}

export const emptyGroups = (): SearchGroups => ({ bots: [], messages: [], rooms: [], routines: [] })

const normalize = (value: string) => value.toLowerCase().replace(/\s+/g, ' ').trim()

export function matchesQuery(query: string, ...fields: (null | string | undefined)[]): boolean {
  const haystack = normalize(fields.filter(Boolean).join(' '))

  return normalize(query)
    .split(' ')
    .every(token => haystack.includes(token))
}

export function plainSnippet(text: string, query: string): string {
  const flat = text
    .replace(/>>>|<<</g, '')
    .replace(/\s+/g, ' ')
    .trim()

  const first = normalize(query).split(' ')[0] || ''
  const at = first ? flat.toLowerCase().indexOf(first) : -1

  if (at < 0 || flat.length <= SNIPPET_RADIUS * 2) {
    return flat.slice(0, SNIPPET_RADIUS * 2)
  }

  const start = Math.max(0, at - SNIPPET_RADIUS)
  const end = Math.min(flat.length, at + first.length + SNIPPET_RADIUS)

  return `${start > 0 ? '…' : ''}${flat.slice(start, end)}${end < flat.length ? '…' : ''}`
}

export function isBotChatHit(result: SearchSnippetResult): boolean {
  return (result.title || '').trim() === CANONICAL_CHAT_TITLE
}

interface LocalSources {
  meta: Record<string, BotMeta>
  rooms: Record<string, GroupChat>
  roster: readonly RosterRow[]
  routines: readonly RoutineSource[]
  routineTitle: (job: RoutineJob) => string
  text: {
    messageIn: (name: string) => string
    roomMembers: (count: number) => string
    routineOf: (bot: string) => string
  }
}

const botKey = (bot: RosterRow) => `${bot.connectionId ?? ''}::${bot.name}`

export function searchLocal(query: string, sources: LocalSources): SearchGroups {
  const groups = emptyGroups()
  const { meta, rooms, roster, routines, routineTitle, text } = sources

  for (const bot of roster) {
    const botMeta = botRosterMeta(bot, meta)
    const name = displayName(bot, botMeta)
    const job = botJob(bot.description, botMeta?.title ?? bot.title)

    if (matchesQuery(query, name, bot.name, job)) {
      groups.bots.push({ bot, key: `bot:${botKey(bot)}`, kind: 'bot', subtitle: job, title: name })
    }
  }

  for (const [name, room] of Object.entries(rooms)) {
    if (room?.tombstone) {
      continue
    }

    const members = room.members ?? []
    const label = name

    if (matchesQuery(query, name, ...members.map(member => member.display_name || member.name))) {
      groups.rooms.push({
        key: `room:${name}`,
        kind: 'room',
        room: name,
        subtitle: text.roomMembers(members.length),
        title: label
      })
    }

    const hit = [...(room.log ?? [])].reverse().find(entry => matchesQuery(query, entry.text))

    if (hit) {
      groups.messages.push({
        key: `room-message:${name}:${hit.id ?? hit.at}`,
        kind: 'room-message',
        room: name,
        subtitle: plainSnippet(hit.text, query),
        title: text.messageIn(label)
      })
    }
  }

  for (const { bot, jobs } of routines) {
    const botMeta = botRosterMeta(bot, meta)

    for (const job of jobs) {
      const title = routineTitle(job)

      if (matchesQuery(query, title, job.prompt, job.prompt_preview)) {
        groups.routines.push({
          bot,
          job,
          key: `routine:${botKey(bot)}:${job.job_id}`,
          kind: 'routine',
          subtitle: text.routineOf(displayName(bot, botMeta)),
          title
        })
      }
    }
  }

  return groups
}

export function chatMessageHits(
  bot: RosterRow,
  query: string,
  results: readonly SearchSnippetResult[],
  messageIn: (name: string) => string,
  name: string
): SearchHit[] {
  return results
    .filter(isBotChatHit)
    .slice(0, SEARCH_GROUP_LIMIT)
    .map(result => ({
      bot,
      key: `chat-message:${botKey(bot)}:${result.session_id}`,
      kind: 'chat-message' as const,
      subtitle: plainSnippet(result.snippet || '', query),
      title: messageIn(name)
    }))
}

export function flattenGroups(groups: SearchGroups): SearchHit[] {
  return [groups.bots, groups.rooms, groups.routines, groups.messages].flatMap(hits =>
    hits.slice(0, SEARCH_GROUP_LIMIT)
  )
}

export function groupTotal(groups: SearchGroups): number {
  return flattenGroups(groups).length
}
