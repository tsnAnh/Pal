import * as sdk from '@hermes/plugin-sdk'
import {
  Button,
  Codicon,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
  GlyphSpinner,
  host,
  queryClient,
  Tip,
  useI18n,
  useQuery
} from '@hermes/plugin-sdk'
import { useRef, useState } from 'react'

import { type BotRunEntry, loadBotRunHistory } from './bot-detail-model'
import { requestBotDelete } from './bot-detail-state'
import { runBotTemplateExport } from './bot-template-export'
import { appBotOf, connectAppsSupported } from './connect-apps'
import { catalogScope } from './connect-apps-dialog'
import { botRosterKey, ROSTER_KEY, saveBotMeta } from './data'
import { useBots } from './i18n'
import type { ProfileDescribeResponse } from './profile-config'
import { RunRow } from './routine-run-panel'
import { routineOwnerKey, supportsRoutineAction } from './routines-api'
import { requestForBot } from './routing'
import { ID } from './shared'
import type { RosterRow, RoutineJob } from './types'

const RUN_POLL_MS = 15000
const DESCRIBE_STALE_MS = 30000

interface BotNameEditorProps {
  bot: RosterRow
  name: string
}

export function BotNameEditor({ bot, name }: BotNameEditorProps) {
  const b = useBots()
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(name)
  const settled = useRef(false)

  const begin = () => {
    settled.current = false
    setDraft(name)
    setEditing(true)
  }

  const finish = async (commit: boolean) => {
    if (settled.current) {
      return
    }

    settled.current = true
    setEditing(false)

    const next = draft.trim()

    if (!commit || !next || next === name.trim()) {
      return
    }

    const saved = await saveBotMeta(bot, { title: next })

    if (saved.serverOutcome === 'persisted') {
      void queryClient.invalidateQueries({ queryKey: ROSTER_KEY })
    } else if (saved.serverOutcome === 'failed') {
      host.notify({ kind: 'error', message: b.avatar.savedLocally })
    }
  }

  if (editing) {
    return (
      <input
        aria-label={b.detail.renameBot}
        autoFocus
        className="mt-3 w-full min-w-0 rounded-md bg-(--chrome-action-hover) px-2 py-0.5 text-center text-xl font-semibold outline-none"
        maxLength={60}
        onBlur={() => void finish(true)}
        onChange={event => setDraft(event.target.value)}
        onFocus={event => event.currentTarget.select()}
        onKeyDown={event => {
          if (event.key === 'Enter') {
            event.preventDefault()
            void finish(true)
          } else if (event.key === 'Escape') {
            event.preventDefault()
            void finish(false)
          }
        }}
        value={draft}
      />
    )
  }

  return (
    <Tip label={b.detail.renameBot}>
      <button
        className="mt-3 max-w-full cursor-text truncate rounded-md px-2 text-xl font-semibold hover:bg-(--chrome-action-hover)"
        data-slot="bot-profile-name"
        onClick={begin}
        type="button"
      >
        {name}
      </button>
    </Tip>
  )
}

export function BotHeaderMenu({ bot }: { bot: RosterRow }) {
  const b = useBots()
  const { t } = useI18n()

  return (
    <DropdownMenu>
      <Tip label={b.detail.moreActions}>
        <DropdownMenuTrigger asChild>
          <Button
            aria-label={b.detail.moreActions}
            className="absolute top-2 left-2 size-8 rounded-full bg-(--chrome-action-hover) text-(--ui-text-secondary) hover:text-foreground"
            size="icon"
            variant="ghost"
          >
            <Codicon name="ellipsis" />
          </Button>
        </DropdownMenuTrigger>
      </Tip>
      <DropdownMenuContent align="start">
        <div className="px-2.5 py-1 text-[0.6875rem] font-medium text-(--ui-text-tertiary)">{b.detail.share}</div>
        <DropdownMenuItem onSelect={() => void runBotTemplateExport(bot)}>
          <Codicon className="mr-1.5" name="export" />
          {b.detail.exportTemplate}
        </DropdownMenuItem>
        <DropdownMenuSeparator />
        <DropdownMenuItem onSelect={() => requestBotDelete(bot)} variant="destructive">
          <Codicon className="mr-1.5" name="trash" />
          {t.common.delete}
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}

function SummaryRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="grid gap-0.5">
      <div className="text-[0.6875rem] font-medium text-(--ui-text-quaternary)">{label}</div>
      <div className="min-w-0 break-words text-sm text-(--ui-text-secondary)">{value}</div>
    </div>
  )
}

function ConnectedAppsValue({ bot }: { bot: RosterRow }) {
  const b = useBots()
  const appBot = appBotOf(bot)

  const view = sdk.useConnectorApps({
    bots: [appBot],
    gateway: typeof host.getGateway === 'function' ? host.getGateway() : null,
    profile: catalogScope()
  })

  const names = [...view.catalog.curated, ...view.catalog.others]
    .filter(app => view.usedBy(app).some(used => used.id === appBot.id))
    .map(app => app.name)

  return <SummaryRow label={b.detail.appsLabel} value={names.length ? names.join(', ') : b.detail.noApps} />
}

interface BotDetailsSummaryProps {
  bot: RosterRow
  job: string
}

export function BotDetailsSummary({ bot, job }: BotDetailsSummaryProps) {
  const b = useBots()

  const { data } = useQuery({
    queryFn: () => requestForBot(bot, 'profiles.describe', { name: bot.name }) as Promise<ProfileDescribeResponse>,
    queryKey: [ID, 'bot-describe', botRosterKey(bot)],
    retry: false,
    staleTime: DESCRIBE_STALE_MS
  })

  const model = data?.model?.default?.trim() || ''
  const skills = Array.isArray(data?.skills) ? data.skills.filter(skill => skill.enabled).length : null

  return (
    <div className="grid gap-3 px-4 pt-1 pb-3" data-slot="bot-details-summary">
      <SummaryRow label={b.detail.jobLabel} value={job || b.detail.noJob} />
      {model ? <SummaryRow label={b.detail.modelLabel} value={model} /> : null}
      {skills === null ? null : <SummaryRow label={b.detail.skillsLabel} value={b.detail.skillsCount(skills)} />}
      {connectAppsSupported ? <ConnectedAppsValue bot={bot} /> : null}
    </div>
  )
}

interface BotRunHistoryPanelProps {
  actions: readonly string[] | undefined
  jobs: readonly RoutineJob[]
  owner: RosterRow
  titleOf: (job: RoutineJob) => string
}

export function BotRunHistoryPanel({ actions, jobs, owner, titleOf }: BotRunHistoryPanelProps) {
  const b = useBots()
  const supported = supportsRoutineAction(actions, 'history')
  const [openKey, setOpenKey] = useState<null | string>(null)

  const history = useQuery({
    enabled: supported && jobs.length > 0,
    queryFn: () => loadBotRunHistory(owner, jobs),
    queryKey: [ID, 'bot-run-history', routineOwnerKey(owner), jobs.map(job => job.job_id).join('|')],
    refetchInterval: RUN_POLL_MS,
    retry: false
  })

  if (!supported) {
    return <div className="px-4 py-2 text-sm text-(--ui-text-tertiary)">{b.detail.historyNeedsUpdate}</div>
  }

  if (history.isLoading && jobs.length > 0) {
    return (
      <div className="flex flex-1 items-center justify-center">
        <GlyphSpinner className="text-(--ui-text-tertiary)" spinner="breathe" />
      </div>
    )
  }

  if (history.error) {
    return <div className="px-4 py-2 text-sm text-(--ui-text-tertiary)">{b.detail.historyFailed}</div>
  }

  const entries: BotRunEntry[] = history.data ?? []

  if (entries.length === 0) {
    return <div className="px-4 py-2 text-sm text-(--ui-text-tertiary)">{b.detail.historyEmpty}</div>
  }

  return (
    <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain" data-slot="bot-run-history">
      <ul className="grid gap-3 px-4 py-2">
        {entries.map(({ job, run }) => {
          const key = `${job.job_id}:${run.run_id}`

          return (
            <li className="grid gap-1" key={key}>
              <div className="truncate text-[0.6875rem] text-(--ui-text-quaternary)">
                {b.detail.historyRoutine(titleOf(job))}
              </div>
              <RunRow
                expanded={openKey === key}
                job={job}
                onToggle={() => setOpenKey(openKey === key ? null : key)}
                owner={owner}
                run={run}
              />
            </li>
          )
        })}
      </ul>
    </div>
  )
}

