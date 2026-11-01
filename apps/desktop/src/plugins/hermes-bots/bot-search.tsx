import {
  Codicon,
  Dialog,
  DialogContent,
  DialogTitle,
  GlyphSpinner,
  host,
  SearchField,
  useQuery,
  useValue
} from '@hermes/plugin-sdk'
import { type KeyboardEvent, useEffect, useMemo, useRef, useState } from 'react'

import { $routineOpenRequest } from './bot-detail-state'
import {
  chatMessageHits,
  emptyGroups,
  flattenGroups,
  MESSAGE_FETCH_LIMIT,
  MESSAGE_MIN_CHARS,
  type RoutineSource,
  SEARCH_CONCURRENCY,
  SEARCH_GROUP_LIMIT,
  type SearchGroups,
  type SearchHit,
  searchLocal,
  type SearchSnippetResult,
  settleLimited
} from './bot-search-model'
import { $botSearchOpen, closeBotSearch, openBotSearch } from './bot-search-state'
import { loadRoutines, routineTitle, selectRoutineJobs } from './cron'
import { $botMeta, $lastRoster, botRosterKey } from './data'
import { $groupChats } from './group-chat'
import { openGroupChat } from './group-chat-view'
import { groupOpenOrigin } from './group-panes'
import { botsText, useBots } from './i18n'
import { displayName } from './labels'
import { openRosterBot } from './roster-actions'
import { backendTargetProfile, botConnectionRoute, botRosterMeta } from './routing'
import { ID } from './shared'
import type { RosterRow } from './types'

const SEARCH_DEBOUNCE_MS = 200
const MAX_SEARCHED_BOTS = 30

type SearchSessionsHost = (
  route: ReturnType<typeof botConnectionRoute>,
  options: { limit?: number; profile: string; query: string }
) => Promise<{ results: SearchSnippetResult[] }>

const messageSearchHost = (): null | SearchSessionsHost => {
  const candidate = (host as { searchPersistedSessions?: SearchSessionsHost }).searchPersistedSessions

  return typeof candidate === 'function' ? candidate : null
}

const servedRoster = (roster: unknown): RosterRow[] =>
  (Array.isArray(roster) ? (roster as RosterRow[]) : []).filter(
    bot => !bot.ghost && !bot.unserved && !bot.sourceMissing
  )

function useDebounced(value: string): string {
  const [debounced, setDebounced] = useState(value)

  useEffect(() => {
    const id = window.setTimeout(() => setDebounced(value), SEARCH_DEBOUNCE_MS)

    return () => window.clearTimeout(id)
  }, [value])

  return debounced
}

function useRoutineSources(roster: readonly RosterRow[], enabled: boolean) {
  return useQuery({
    enabled: enabled && roster.length > 0,
    queryFn: async (): Promise<RoutineSource[]> => {
      const settled = await settleLimited(roster.slice(0, MAX_SEARCHED_BOTS), SEARCH_CONCURRENCY, async bot => {
        const data = await loadRoutines(bot)

        return { bot, jobs: selectRoutineJobs(data, null, [], bot.name).jobs }
      })

      return settled.flatMap(result => (result.status === 'fulfilled' ? [result.value] : []))
    },
    queryKey: [ID, 'bot-search-routines', roster.map(botRosterKey).join('|')],
    retry: false,
    staleTime: 15000
  })
}

function useMessageHits(query: string, roster: readonly RosterRow[], enabled: boolean) {
  const search = messageSearchHost()
  const names = useMemo(() => roster.map(botRosterKey).join('|'), [roster])

  const result = useQuery({
    enabled: enabled && Boolean(search) && query.length >= MESSAGE_MIN_CHARS,
    queryFn: async (): Promise<SearchHit[]> => {
      const copy = botsText().detail

      const settled = await settleLimited(roster.slice(0, MAX_SEARCHED_BOTS), SEARCH_CONCURRENCY, async bot => {
        const route = botConnectionRoute(bot)

        const found = await search!(route, {
          limit: MESSAGE_FETCH_LIMIT,
          profile: backendTargetProfile(route, bot.name),
          query
        })

        return chatMessageHits(
          bot,
          query,
          found.results,
          copy.messageIn,
          displayName(bot, botRosterMeta(bot, $botMeta.get()))
        )
      })

      return settled.flatMap(item => (item.status === 'fulfilled' ? item.value : []))
    },
    queryKey: [ID, 'bot-search-messages', names, query],
    retry: false,
    staleTime: 15000
  })

  return { ...result, supported: Boolean(search) }
}

function openHit(hit: SearchHit) {
  closeBotSearch()

  switch (hit.kind) {
    case 'bot':

    case 'chat-message':
      void openRosterBot(hit.bot)

      return

    case 'routine':
      void openRosterBot(hit.bot)
      $routineOpenRequest.set({ botKey: botRosterKey(hit.bot), jobId: hit.job.job_id })

      return

    default:
      openGroupChat(hit.room, groupOpenOrigin(hit.room))
  }
}

const HIT_ICON = {
  bot: 'hubot',
  'chat-message': 'comment',
  room: 'organization',
  'room-message': 'comment',
  routine: 'history'
} as const

function HitRow({ active, hit, id, onHover }: { active: boolean; hit: SearchHit; id: string; onHover: () => void }) {
  return (
    <div
      aria-selected={active}
      className="flex min-w-0 cursor-pointer items-center gap-2.5 rounded-md px-2.5 py-1.5 aria-selected:bg-(--chrome-action-hover)"
      id={id}
      onClick={() => openHit(hit)}
      onMouseMove={onHover}
      role="option"
    >
      <Codicon className="shrink-0 text-(--ui-text-tertiary)" name={HIT_ICON[hit.kind]} />
      <div className="min-w-0 flex-1">
        <div className="truncate text-sm text-foreground">{hit.title}</div>
        {hit.subtitle ? <div className="truncate text-xs text-(--ui-text-tertiary)">{hit.subtitle}</div> : null}
      </div>
    </div>
  )
}

function SearchBody({ onClose }: { onClose: () => void }) {
  const b = useBots()
  const roster = servedRoster(useValue($lastRoster))
  const meta = useValue($botMeta)
  const rooms = useValue($groupChats)
  const [input, setInput] = useState('')
  const [active, setActive] = useState(0)
  const inputRef = useRef<HTMLInputElement>(null)
  const query = useDebounced(input).trim()
  const searching = query.length > 0
  const routineSources = useRoutineSources(roster, searching)
  const messages = useMessageHits(query, roster, searching)
  const text = b.detail

  const groups: SearchGroups = useMemo(() => {
    if (!query) {
      return emptyGroups()
    }

    const local = searchLocal(query, {
      meta,
      rooms,
      roster,
      routineTitle: job => routineTitle(job, b.cron),
      routines: routineSources.data ?? [],
      text
    })

    return { ...local, messages: [...local.messages, ...(messages.data ?? [])] }
  }, [b.cron, messages.data, meta, query, roster, rooms, routineSources.data, text])

  const flat = flattenGroups(groups)
  const pending = searching && (input.trim() !== query || routineSources.isFetching || messages.isFetching)

  const sections = [
    [text.groupBots, groups.bots],
    [text.groupRooms, groups.rooms],
    [text.groupRoutines, groups.routines],
    [text.groupMessages, groups.messages]
  ] as const

  useEffect(() => setActive(0), [query])

  useEffect(() => {
    document.getElementById(`bot-search-hit-${active}`)?.scrollIntoView?.({ block: 'nearest' })
  }, [active])

  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault()

      if (flat.length > 0) {
        setActive(current => (current + (event.key === 'ArrowDown' ? 1 : -1) + flat.length) % flat.length)
      }
    } else if (event.key === 'Enter' && flat[active]) {
      event.preventDefault()
      openHit(flat[active])
    } else if (event.key === 'Escape') {
      onClose()
    }
  }

  let offset = 0

  return (
    <div className="grid min-h-0 gap-2">
      <SearchField
        aria-label={text.searchTitle}
        inputRef={inputRef}
        loading={pending}
        onChange={setInput}
        onKeyDown={onKeyDown}
        placeholder={text.searchPlaceholder}
        value={input}
        variant="box"
      />
      <div
        aria-activedescendant={flat.length ? `bot-search-hit-${active}` : undefined}
        aria-label={text.searchTitle}
        className="grid max-h-[26rem] min-h-32 content-start gap-2 overflow-y-auto overscroll-contain"
        role="listbox"
      >
        {!searching ? <div className="px-2.5 py-3 text-sm text-(--ui-text-tertiary)">{text.searchHint}</div> : null}
        {searching && flat.length === 0 && pending ? (
          <div className="flex items-center gap-2 px-2.5 py-3 text-sm text-(--ui-text-tertiary)">
            <GlyphSpinner spinner="breathe" />
            {text.searching}
          </div>
        ) : null}
        {searching && flat.length === 0 && !pending ? (
          <div className="px-2.5 py-3 text-sm text-(--ui-text-tertiary)" role="status">
            {text.noResults(query)}
          </div>
        ) : null}
        {sections.map(([label, hits]) => {
          const shown = hits.slice(0, SEARCH_GROUP_LIMIT)

          if (shown.length === 0) {
            return null
          }

          const start = offset

          offset += shown.length

          return (
            <div className="grid gap-0.5" key={label} role="group">
              <div className="px-2.5 pt-1 text-[0.6875rem] font-medium text-(--ui-text-quaternary)">{label}</div>
              {shown.map((hit, index) => (
                <HitRow
                  active={start + index === active}
                  hit={hit}
                  id={`bot-search-hit-${start + index}`}
                  key={hit.key}
                  onHover={() => setActive(start + index)}
                />
              ))}
            </div>
          )
        })}
        {searching && !messages.supported ? (
          <div className="px-2.5 py-1 text-[0.6875rem] text-(--ui-text-quaternary)">{text.messagesUnavailable}</div>
        ) : null}
      </div>
    </div>
  )
}

export function BotSearchDialog() {
  const open = useValue($botSearchOpen)
  const b = useBots()

  useEffect(() => {
    const onKey = (event: globalThis.KeyboardEvent) => {
      const botMode = 'botMode' in document.documentElement.dataset

      if (
        botMode &&
        (event.metaKey || event.ctrlKey) &&
        !event.altKey &&
        !event.shiftKey &&
        event.key.toLowerCase() === 'k'
      ) {
        event.preventDefault()
        event.stopPropagation()
        openBotSearch()
      }
    }

    window.addEventListener('keydown', onKey, { capture: true })

    return () => window.removeEventListener('keydown', onKey, { capture: true })
  }, [])

  return (
    <Dialog onOpenChange={next => !next && closeBotSearch()} open={open}>
      <DialogContent className="max-w-xl gap-3 p-3">
        <DialogTitle className="sr-only">{b.detail.searchTitle}</DialogTitle>
        {open ? <SearchBody onClose={closeBotSearch} /> : null}
      </DialogContent>
    </Dialog>
  )
}
